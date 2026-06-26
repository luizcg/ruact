# frozen_string_literal: true

require "json"
require "socket"
require "uri"
require_relative "validation_errors_collector"

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
  # rubocop:disable Metrics/ModuleLength
  module Controller
    extend ActiveSupport::Concern

    include Ruact::ValidationErrorsCollector

    private

    # Returns the boot-time cached manifest (set by Railtie#config.to_prepare).
    # No per-request file I/O (AC#6).
    def ruact_manifest
      Ruact.manifest
    end

    # Only activate RSC rendering for HTML-like requests (AC FR26).
    # JSON, XML, and other formats bypass RSC entirely so respond_to blocks
    # and explicit render calls work without interference.
    def default_render
      if ruact_template_exists? && (request.format.html? || ruact_request?)
        ruact_render
      else
        super
      end
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
          render html: ruact_html_shell(payload).html_safe, layout: false
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

    def ruact_html_shell(flight_payload)
      escaped_payload = flight_payload.gsub("</script>", '<\/script>')
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            #{ruact_csrf_meta_tag}
            <title>Rails RSC</title>
            #{vite_tags}
          </head>
          <body>
            <div id="root"></div>
            <script>
              (function() {
                var d = (self.__FLIGHT_DATA = self.__FLIGHT_DATA || []);
                d.push(#{escaped_payload.inspect});
              })();
            </script>
          </body>
        </html>
      HTML
    end

    # Story 8.3 review R7 — emits `<meta name="csrf-token" content="...">`
    # into the shell so the JS runtime's `<meta>` lookup can forward a
    # valid `X-CSRF-Token` on every server-function (mutation) call. Without
    # this, hosts that route `ruact_render` through the gem's HTML shell (the
    # standard path) have no token in the document and the host's
    # `protect_from_forgery` rejects every non-GET server function.
    #
    # Returns an empty string when CSRF protection isn't available
    # (non-Rails specs, or hosts that have deliberately stripped
    # `form_authenticity_token` from the controller surface).
    def ruact_csrf_meta_tag
      return "" unless respond_to?(:form_authenticity_token, true)

      token = form_authenticity_token
      return "" if token.nil? || token.empty?

      %(<meta name="csrf-token" content="#{ERB::Util.html_escape(token)}" />)
    rescue StandardError
      ""
    end

    def vite_tags
      if Rails.env.development? && vite_dev_running?
        # @vitejs/plugin-react normally injects this preamble by processing index.html.
        # Since our HTML is generated by Rails (not Vite), we inject it manually.
        # Without it, every JSX file throws "can't detect preamble" at runtime.
        react_preamble = <<~JS
          <script type="module">
            import RefreshRuntime from 'http://localhost:5173/@react-refresh';
            RefreshRuntime.injectIntoGlobalHook(window);
            window.$RefreshReg$ = () => {};
            window.$RefreshSig$ = () => (type) => type;
            window.__vite_plugin_react_preamble_installed__ = true;
          </script>
        JS

        react_preamble + <<~HTML
          <script type="module" src="http://localhost:5173/@vite/client"></script>
          <script type="module" src="http://localhost:5173/app/javascript/application.jsx"></script>
        HTML
      else
        # Production: read hashed URL from Vite manifest
        entry = vite_manifest_entry("app/javascript/application.jsx")
        src   = entry ? "/assets/#{entry['file']}" : "/assets/application.js"
        %(<script type="module" src="#{src}"></script>)
      end
    end

    def vite_dev_running?
      require "socket"
      Socket.tcp("localhost", 5173, connect_timeout: 1).close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
      false
    end

    def vite_manifest_entry(src_path)
      manifest_path = Rails.root.join("public", "assets", ".vite", "manifest.json")
      return nil unless File.exist?(manifest_path)

      JSON.parse(File.read(manifest_path))[src_path]
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
