# frozen_string_literal: true

require "json"
require "socket"
require "uri"
require_relative "view_helper"
require_relative "validation_errors_collector"
require_relative "controller/document_rendering"

module Ruact
  # Include in ApplicationController to enable RSC rendering.
  #
  #   class ApplicationController < ActionController::Base
  #     include Ruact::Controller
  #   end
  #
  # After that, any action whose view is a .html.erb file will automatically:
  # - Respond to text/x-component requests with a raw Flight payload
  # - Respond to text/html requests with an HTML shell + inline Flight payload
  module Controller
    extend ActiveSupport::Concern

    include Ruact::ValidationErrorsCollector
    # Story 14.2 (FR104) — the JS asset markup (entry `<script>` tags +
    # `__FLIGHT_DATA`) lives in one place: `Ruact::ViewHelper#ruact_js_assets`.
    # The controller mixes the helper in so `ruact_html_shell` delegates to that
    # single implementation (controller↔helper parity — no duplicated tag logic),
    # and so the shared `vite_dev_running?` / `vite_manifest_entry` helpers are
    # reachable here without duplication.
    include Ruact::ViewHelper
    # Who owns the `<head>` — the host app's layout, with ruact's built-in shell
    # as the un-migrated fallback. See Ruact::Controller::DocumentRendering.
    include Ruact::Controller::DocumentRendering

    private

    # `ruact_js_assets` / `__ruact_component__` are public VIEW helpers, but on a
    # controller a public instance method is exposed as a routable action. Demote
    # the mixed-in helper methods so they are never callable as actions (they are
    # only ever invoked internally by `ruact_html_shell`).
    private :ruact_js_assets, :__ruact_component__

    # Resolves the manifest for this render. In PRODUCTION this is the boot-time
    # cached +Ruact.manifest+ (set by Railtie#config.to_prepare) — no per-request
    # I/O. In DEVELOPMENT it fetches the live manifest from the Vite dev server
    # (falling back to the on-disk file, then a clear error), killing the
    # boot-race where Rails read the missing file before Vite wrote it and every
    # first request 500'd on +nil.reference_for+. Called once per render; the
    # returned manifest is held by RenderPipeline for the whole render (not
    # re-fetched per component). See {Ruact::ManifestResolver}.
    def ruact_manifest
      ManifestResolver.resolve
    end

    # Only activate RSC rendering when the matching .html.erb template exists AND
    # the client will accept an HTML response (AC FR26; Story 10.0).
    # `request.format.html?` is false for a `*/*` wildcard (curl/bots/
    # health-checks), so checking it alone routed those requests through `super`,
    # which compiled+rendered the `.html.erb` outside a `ruact_render` flow and
    # 500'd with "__ruact_component__ called outside a ruact_render flow".
    # Checking HTML acceptability instead serves `*/*` the same HTML shell a
    # browser gets. Concrete non-HTML formats (application/json, application/xml)
    # carry no html/wildcard accept → still bypass to `super` so respond_to
    # blocks and explicit render calls work without interference.
    def default_render
      if ruact_template_exists? && (ruact_request? || ruact_html_acceptable?)
        ruact_render
      else
        super
      end
    end

    # True when the client will accept an HTML response: an absent Accept (Rails
    # defaults to HTML) or any acceptable type that is HTML or the `*/*` wildcard.
    # `Mime::ALL.html?` is false, so the explicit `== Mime::ALL` check is required
    # to recognize the wildcard (`*/*`) alongside concrete `text/html`. A nil
    # entry (from an empty/unparseable Accept token) is treated as "accept
    # anything" so a blank Accept degrades to HTML rather than raising.
    #
    # This is a MEMBERSHIP test, not a priority/quality negotiation: a mixed
    # `application/json, text/html` (HTML listed alongside a concrete API format)
    # activates the HTML shell, because `default_render` is only ever reached on
    # an action that did NOT explicitly render — there is no JSON representation
    # to prefer, and the client did say it accepts HTML. A purely concrete
    # non-HTML Accept (`application/json`, `application/json, application/xml`)
    # has no html/wildcard member and still bypasses to `super` (AC4).
    # `Mime::Type.parse` discards `q` values, so an exotic `text/html;q=0` is
    # treated as acceptable rather than as an explicit rejection — out of scope
    # for the implicit-render contract (see story 10.0 deferred note).
    def ruact_html_acceptable?
      accepts = request.accepts
      accepts.blank? || accepts.any? { |type| type.nil? || type == Mime::ALL || type.html? }
    end

    # Render the RSC view for the current action using ActionView's full pipeline.
    # ActionView handles layouts, partials, and helpers — the ErbPreprocessorHook
    # ensures all PascalCase tags are transformed before template compilation.
    #
    # Called automatically when no explicit render is performed and a matching
    # .html.erb template exists. Can also be called explicitly with options.
    #
    # +template+: logical template name (e.g. "posts/custom"), or nil to use
    #             the current action's default template.
    # +locals+:   hash of local variables to pass to the template.
    def ruact_render(template: nil, locals: {})
      # Story 13.3 (FR98, AC4) — seed the collector from a redirect-back flash
      # before the view evaluates, so `errors={ruact_errors}` surfaces surviving
      # errors (no-op on a plain render — `ruact_errors` then returns `{}`).
      __ruact_read_errors_from_flash

      pipeline  = RenderPipeline.new(ruact_manifest, controller_path: controller_path, logger: logger)
      streaming = ruact_request? && self.class.ancestors.include?(ActionController::Live)

      # Allocate a per-render context and expose it to the view via a normal
      # (non-`@_`-prefixed) instance variable on the controller. Rails 8's
      # `render_to_string` allocates a fresh `ActionView::Base` distinct from
      # `controller.view_context`; setting the ivar on `view_context` does not
      # reach that view. By contrast, controller ivars *not* matching
      # `AbstractController::Base::DEFAULT_PROTECTED_INSTANCE_VARIABLES`
      # (i.e. anything not prefixed with `@_`) are copied to the view via
      # `_assigns_for_view_context`, so the view evaluated inside
      # `render_to_string` receives `@ruact_render_context` populated.
      # ViewHelper#__ruact_component__ reads it during ERB evaluation. The
      # controller instance is per-request (Rails allocates a new one per
      # action), so this is per-request safe under multi-threaded servers
      # (NFR8). See Story 7.9 / Bug 7.8-B.
      with_render_context do |render_context|
        opts = template ? { template: template } : { action: action_name }
        html = render_to_string(opts.merge(layout: false, locals: locals))
        emit_ruact_response(pipeline, html, render_context, streaming: streaming)
      end
    end

    # Allocates a fresh `Ruact::RenderContext`, exposes it as the
    # `@ruact_render_context` ivar for the duration of the block, then
    # restores the controller's prior ivar state. When the ivar wasn't
    # defined before this call, `remove_instance_variable` puts the
    # controller back in its original state — restoring it as a defined
    # `nil` would leak a phantom assignment into `view_assigns`
    # (`{"ruact_render_context" => nil}`) on any subsequent error/rescue
    # render in the same request.
    def with_render_context
      had_previous = instance_variable_defined?(:@ruact_render_context)
      previous     = @ruact_render_context if had_previous
      render_context = RenderContext.new
      @ruact_render_context = render_context
      begin
        yield render_context
      ensure
        if had_previous
          @ruact_render_context = previous
        else
          remove_instance_variable(:@ruact_render_context)
        end
      end
    end

    # Build the wire output and write it to the response. Streaming responses
    # only fire after `pipeline.render` returns without raising — that way a
    # missing-component error can still surface as a normal 500 response
    # (matching the legacy `#from_html` ordering) before any streaming
    # response headers are mutated.
    def emit_ruact_response(pipeline, html, render_context, streaming:)
      # Story 15.5 (FR109) — record which page shape ruact rendered so the
      # `Ruact::Server` dev log (`__ruact_log_response_shape!`) can name it and,
      # crucially, stay SILENT on a plain Rails render (this flag is never set
      # there). `@__`-prefixed → never leaks into `view_assigns`.
      @__ruact_negotiated_page = ruact_request? ? :flight : :html_shell

      if ruact_request? && streaming
        enumerator = pipeline.render({ html: html, render_context: render_context }, mode: :stream)
        response.headers["Content-Type"]      = "text/x-component; charset=utf-8"
        response.headers["Cache-Control"]     = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
        begin
          enumerator.each { |row| response.stream.write(row) }
        ensure
          response.stream.close
        end
      else
        payload = pipeline.render({ html: html, render_context: render_context }, mode: :string)
        if ruact_request?
          render plain: payload, content_type: "text/x-component"
        else
          render_ruact_document(payload)
        end
      end
    end

    # Overrides Rails redirect_to for RSC requests: emits a Flight redirect row
    # (`0:{"redirectUrl":"...","redirectType":"push"}`) instead of a 302 response.
    # This allows the client-side router to handle the navigation without an extra
    # HTTP round-trip.  Non-RSC requests and external-origin redirects fall through
    # to the standard Rails implementation.
    def redirect_to(options = {}, response_options = {})
      return super unless ruact_request?

      url = url_for(options)

      begin
        uri = ::URI.parse(url)
        # External origin: fall back to standard 302 so the browser follows it normally.
        # Compare host, port, and scheme to avoid treating same-host-different-port as same-origin.
        if uri.host
          return super if uri.host != request.host
          return super if uri.port && uri.port != request.port
          return super if uri.scheme && uri.scheme != request.scheme
        end

        redirect_url  = uri.path.nil? || uri.path.empty? ? "/" : uri.path
        redirect_url += "?#{uri.query}"    if uri.query
        redirect_url += "##{uri.fragment}" if uri.fragment
      rescue ::URI::InvalidURIError
        return super
      end

      # Story 13.3 (FR98, AC4) — the Inertia "redirect back with errors" path:
      # stash any `ruact_errors`-registered errors in flash so they survive this
      # Flight redirect and re-render as an `errors` prop (no-op when untouched).
      __ruact_stash_errors_in_flash

      # Story 15.5 (FR109) — mark the Flight-redirect sub-shape for the dev log.
      @__ruact_negotiated_page = :flight_redirect

      render plain: "0:#{JSON.generate({ 'redirectUrl' => redirect_url, 'redirectType' => 'push' })}\n",
             content_type: "text/x-component"
    end

    def ruact_request?
      request.headers["Accept"]&.include?("text/x-component") ||
        request.headers["Ruact-Request"] == "1"
    end

    def ruact_template_exists?
      File.exist?(default_template_path)
    end

    def default_template_path
      action = action_name
      controller = self.class.name.underscore.sub("_controller", "")
      Rails.root.join("app", "views", controller, "#{action}.html.erb")
    end
  end
end
