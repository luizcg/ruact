# frozen_string_literal: true

require "erb"
require "json"
require "socket"

module Ruact
  # ActionView helper module included in ActionView::Base via Railtie.
  # Provides the +__ruact_component__+ method that ERB templates call after the
  # preprocessor transforms PascalCase tags into +<%= __ruact_component__(...) %>+.
  #
  # Thread-safe: ActionView creates a fresh view context per request, so the
  # render context (set by Ruact::Controller#ruact_render on the controller as
  # +@ruact_render_context+ and copied to the view by Rails's view_assigns
  # plumbing — see Story 7.9 / Bug 7.8-B) is per-request — no shared state.
  module ViewHelper
    # Registers +name+ with +props+ in the per-render RenderContext (set by
    # Ruact::Controller#ruact_render on the controller as +@ruact_render_context+;
    # Rails copies it to the view via +_assigns_for_view_context+ because the
    # name does not match +DEFAULT_PROTECTED_INSTANCE_VARIABLES+'s +/\A@_/+
    # filter) and returns an HTML comment placeholder that HtmlConverter later
    # replaces with a ReactElement node.
    #
    # The returned string MUST be html_safe so ActionView does not escape the
    # angle brackets — if it were escaped, HtmlConverter would not find the
    # placeholder in the HTML output.
    def __ruact_component__(name, props = {})
      ctx = @ruact_render_context
      raise Ruact::Error, __ruact_outside_render_message(name) if ctx.nil?

      token = ctx.register(name, props)
      "<!-- #{token} -->".html_safe
    end

    # Story 18-2 — the opening of a component with children. Registers it like
    # {#__ruact_component__} and opens the wrapper element whose content (the
    # ERB between the tags, evaluated in place) HtmlConverter hands the
    # component as `children`. The preprocessor writes the matching
    # `</ruact-component>`.
    def __ruact_component_open__(name, props = {})
      ctx = @ruact_render_context
      raise Ruact::Error, __ruact_outside_render_message(name) if ctx.nil?

      token = ctx.register(name, props)
      %(<ruact-component data-ruact-token="#{token}">).html_safe
    end

    # Story 17.0i — a client component in a template Rails is rendering on its
    # own. Says which component and template, and the two ways to a ruact page:
    # `ruact_render` for this template, or listing the action in the
    # controller's `ruact_pages`. The file and line come from the
    # `ActionView::Template::Error` Rails wraps this in.
    def __ruact_outside_render_message(name)
      template = @current_template&.virtual_path
      where = template ? "\"#{template}\"" : "this template"
      # The helper is in every view. A controller action without the concern
      # has no `ruact_render` to call; a mailer (its view's `controller`) or a
      # `Controller.render` that ran no action cannot render through ruact at all.
      owner = respond_to?(:controller) ? controller : nil
      declined = owner&.instance_variable_get(:@__ruact_declined_render_options)
      return __ruact_declined_options_message(name, where, declined) if declined.present?

      if owner && !(defined?(Ruact::Controller) && owner.class.include?(Ruact::Controller) &&
                    __ruact_page_request?(owner))
        return __ruact_not_a_page_message(name, where) unless __ruact_page_request?(owner)

        return "ruact: <#{name} /> is a client component, and #{where} is being rendered by " \
               "#{owner.class.name}, which does not include Ruact::Controller. Add " \
               "`include Ruact::Controller` to it: its pages then render through ruact."
      end

      # A partial or a layout is not a page: rendering it as one is not the fix.
      call = if template.nil? || File.basename(template).start_with?("_") || template.start_with?("layouts/")
               "`ruact_render(template: …, status: …)` for the page that renders it"
             else
               "`ruact_render(template: \"#{template}\", status: …)`"
             end
      "ruact: <#{name} /> is a client component, and #{where} is being rendered by Rails, outside ruact. " \
        "Render it through ruact: #{call} — or, when it is this controller's page and the controller " \
        "declares `ruact_pages`, add the action there (`render :action` then goes through ruact)."
    end

    # A controller answering a request with an action — not a mailer, not an
    # `ActionController::Renderer` (no action ran).
    def __ruact_page_request?(owner)
      defined?(ActionController::Metal) && owner.is_a?(ActionController::Metal) && owner.action_name.present?
    end

    # Story 17.0i review R3 — the page was ruact's, but `render` carried an
    # option ruact does not take, so Rails rendered it.
    def __ruact_declined_options_message(name, where, options)
      named = options.map { |option| "`#{option}:`" }.join(", ")
      "ruact: <#{name} /> is a client component, and #{where} is a ruact page, but its `render` got " \
        "#{named} — not a render option ruact takes — so Rails rendered it outside ruact. Remove it " \
        "(a flash message goes in `flash.now`), or render the page with `ruact_render`."
    end

    def __ruact_not_a_page_message(name, where)
      "ruact: <#{name} /> is a client component, and #{where} is being rendered outside a request to a " \
        "ruact controller (a mailer, or `Controller.render`). Client components render only in a page a " \
        "ruact controller renders."
    end

    private :__ruact_outside_render_message, :__ruact_page_request?, :__ruact_not_a_page_message,
            :__ruact_declined_options_message

    # Story 14.2 (FR104) — emits ruact's full JavaScript asset block: the
    # dev/prod bootstrap entry `<script>` tags (re-targeting the virtual entry
    # `virtual:ruact/bootstrap` — in dev the react-refresh preamble + `@vite/client`
    # + the bootstrap module; in prod the hashed URL read from the Vite manifest)
    # AND, when a Flight payload is given, the `__FLIGHT_DATA` inline bootstrap
    # `<script>` the entry reads on boot.
    #
    # This is the SINGLE implementation of the JS asset markup —
    # `Ruact::Controller#ruact_html_shell` delegates to it so the controller's
    # generated shell and any view that calls the helper emit byte-identical tags
    # (no drift). Available in every view via the railtie's
    # `ActionView::Base.include(Ruact::ViewHelper)`.
    #
    # Called from a LAYOUT the argument is normally omitted: the payload for the
    # render in flight is picked up from `@ruact_flight_payload`, which
    # `Ruact::Controller#render_ruact_document` sets on the controller and Rails
    # copies to the view (the name does not match the `/\A@_/` protected-ivar
    # filter). On a plain Rails page — no ruact render in flight — that ivar is
    # absent and the helper emits only the entry tags, exactly as before.
    #
    # @param flight_payload [String, nil] the per-render Flight wire payload to
    #   inline as `__FLIGHT_DATA`. Omit inside a layout to use the render in
    #   flight; an explicit argument always wins.
    # @return [ActiveSupport::SafeBuffer] the asset markup, html_safe
    # @example In a layout
    #   <%= ruact_js_assets %>
    def ruact_js_assets(flight_payload = nil)
      flight_payload ||= @ruact_flight_payload
      parts = []
      parts << ruact_flight_data_script(flight_payload) unless flight_payload.nil?
      parts << ruact_vite_tags
      parts.join("\n").html_safe
    end

    # The `<head>` half of the asset contract: the stylesheets Vite emitted for
    # the client components, linked so they reach the page in production.
    #
    # Vite is an ASSET bundler, not a JS bundler — a `"use client"` component
    # that imports CSS (its own, or one a package ships) produces a stylesheet
    # recorded on the manifest entry beside `file`. Nothing linked it, so the
    # styling was built, digest-stamped, served and never referenced. Only
    # production was affected: the dev server injects that CSS through JS.
    #
    # **Why this is separate from {#ruact_js_assets}, and why it belongs in
    # `<head>`.** The JS helper is injected before `</body>`, and the built-in
    # shell emits it there too — a position that did not matter while it emitted
    # only a `<script>`. A stylesheet there is discovered late and sits AFTER
    # when the browser finds it, and it means third-party CSS outranks the app's
    # own. So ruact declares that it contributes CSS and says WHERE, rather than
    # smuggling it through a helper named for JavaScript.
    #
    # **Cascade.** Call it ABOVE the app's `stylesheet_link_tag`, so the app's
    # own CSS is loaded afterwards. The layout ruact ships (`layouts/ruact`,
    # Story 17.0b) does exactly that; a layout of the app's own does it by hand
    # (`rails generate ruact:install` prints the line, it never edits a layout).
    # Order decides ties only — specificity, `!important` and cascade layers all
    # outrank it — but ties are the common case, and losing them by default is
    # what makes third-party CSS feel like it "takes over".
    #
    # **With the dev server reachable it links no stylesheet**, deliberately:
    # Vite is already injecting the CSS, and linking the file on disk would serve
    # whatever the last build left there. In development WITHOUT the dev server it
    # falls back to the built manifest, matching what `ruact_vite_tags` does.
    #
    # It reads the SAME manifest entry as {#ruact_js_assets}, in the same render,
    # so the script and the stylesheet can never come from different builds.
    #
    # **In a document ruact renders it also emits
    # `<meta name="turbo-visit-control" content="reload">`** (Story 17.0f), in
    # every environment: Turbo Drive then loads a ruact page in full instead of
    # swapping it into its own document. Outside a ruact render — the same layout
    # rendering a plain Rails page — it does not.
    #
    # @return [ActiveSupport::SafeBuffer] the meta (in a ruact document) followed
    #   by the `<link>` markup, html_safe; no links in development with Vite
    #   running, when no entry exists, or when the entry declares no CSS
    # @example In a layout
    #   <head>
    #     <%= ruact_head_assets %>
    #     <%= stylesheet_link_tag :app %>
    #   </head>
    def ruact_head_assets
      tags = []
      tags.push(TURBO_VISIT_CONTROL, TURBO_PREFETCH) if ruact_document?
      tags.concat(ruact_component_stylesheets) unless Rails.env.development? && vite_dev_running?
      tags.join("\n").html_safe
    end

    # Story 17.0f (FR117) — a document ruact rendered must not be swapped into
    # the page by Turbo Drive: Turbo would keep ITS document, the ruact bootstrap
    # (a module script, evaluated once per document) would not run again, and
    # the two routers would end up fighting over one page — dead links and
    # blank pages after a single round trip (spike 2026-09-12, S3–S7). With this
    # meta Turbo does a full load instead. It does not depend on Vite, so it is
    # emitted in development too.
    TURBO_VISIT_CONTROL = %(<meta name="turbo-visit-control" content="reload">)

    # Story 17.0f (decided by Luiz, 2026-09-25) — in a document ruact rendered,
    # the ruact router owns every click, but a layout that also loads Turbo 8
    # still lets Turbo PREFETCH links on hover: a GET that runs the destination's
    # action for a click Turbo will never handle (seen in playgrounds/
    # nav-islands). Off in ruact documents; untouched everywhere else.
    TURBO_PREFETCH = %(<meta name="turbo-prefetch" content="false">)

    private

    # Whether the document being rendered is ruact's. `render_ruact_document`
    # sets `@ruact_flight_payload` for the whole render (copied into the view by
    # Rails), and removes it after. The same layout rendering a plain Rails page
    # — the app's layout, in whole-app mode — does not have it, and must not
    # tell Turbo to reload every visit.
    def ruact_document?
      instance_variable_defined?(:@ruact_flight_payload) && !@ruact_flight_payload.nil?
    end

    def ruact_component_stylesheets
      entry = vite_manifest_entry(Ruact.bootstrap_virtual_id)
      return [] if entry.nil?

      Array(entry["css"]).map { |file| %(<link rel="stylesheet" href="/assets/#{file}">) }
    end

    # The `__FLIGHT_DATA` inline bootstrap `<script>` — pushes the per-render
    # Flight payload onto the global queue the bootstrap entry drains on boot.
    #
    # The payload carries application data (props, record content), so it is
    # embedded as a JSON string literal with `<`, `>`, `&`, U+2028 and U+2029
    # escaped as `\uXXXX`. No byte of the payload can then close the `<script>`
    # — `</SCRIPT>`, `</script >` and `<!--` included — and every character
    # reaches JavaScript intact (a Ruby `String#inspect` literal did neither:
    # it escaped only a lowercase `</script>`, and its `\e`-style escapes mean
    # something else in JS).
    SCRIPT_UNSAFE = /[<>&\u2028\u2029]/
    private_constant :SCRIPT_UNSAFE

    # A JSON string literal that is also safe inside a `<script>` element.
    # The payload is UTF-8 by construction (the serializer normalizes every
    # string); a binary-tagged buffer is retagged, not transcoded.
    def __ruact_script_safe_json(string)
      utf8 = string.encoding == Encoding::UTF_8 ? string : string.dup.force_encoding(Encoding::UTF_8)
      JSON.generate(utf8).gsub(SCRIPT_UNSAFE) { |char| format("\\u%04x", char.ord) }
    end

    def ruact_flight_data_script(flight_payload)
      <<~HTML.strip
        <script>
          (function() {
            var d = (self.__FLIGHT_DATA = self.__FLIGHT_DATA || []);
            d.push(#{__ruact_script_safe_json(flight_payload)});
          })();
        </script>
      HTML
    end

    # The bootstrap entry `<script>` tags — dev serves the virtual module from
    # the Vite dev server (with the react-refresh preamble + `@vite/client`);
    # prod reads the hashed URL from the Vite manifest. Both target the SAME
    # virtual entry id (`Ruact.bootstrap_virtual_id`) so dev/prod stay in lockstep.
    def ruact_vite_tags
      if Rails.env.development? && vite_dev_running?
        # @vitejs/plugin-react normally injects this preamble by processing index.html.
        # Since our HTML is generated by Rails (not Vite), we inject it manually.
        # Without it, every JSX file throws "can't detect preamble" at runtime.
        dev_server = Ruact.config.vite_dev_server.chomp("/")
        react_preamble = <<~JS
          <script type="module">
            import RefreshRuntime from '#{dev_server}/@react-refresh';
            RefreshRuntime.injectIntoGlobalHook(window);
            window.$RefreshReg$ = () => {};
            window.$RefreshSig$ = () => (type) => type;
            window.__vite_plugin_react_preamble_installed__ = true;
          </script>
        JS

        react_preamble + <<~HTML
          <script type="module" src="#{dev_server}/@vite/client"></script>
          <script type="module" src="#{ruact_bootstrap_dev_url}"></script>
        HTML
      else
        # Production: read the hashed URL from the Vite manifest, keyed on the
        # virtual entry id (the manifest key Vite emits for the virtual input).
        entry = vite_manifest_entry(Ruact.bootstrap_virtual_id)
        src   = entry ? "/assets/#{entry['file']}" : "/assets/application.js"
        tag   = %(<script type="module" src="#{src}"></script>)
        # Story 17-0k — in development with neither the Vite dev server nor a
        # build, that script 404s and the page stays empty with no error.
        Rails.env.development? && entry.nil? ? "#{ruact_vite_down_warning}\n#{tag}" : tag
      end
    end

    # Story 17-0k — `bin/rails server` on its own, once Vite has run before:
    # the component manifest is on disk, so the render succeeds, but the page's
    # JavaScript is not served and `#root` stays empty — a blank 200 whose only
    # clue was a 404 in the network tab. Development only. Plain HTML with
    # inline style: the warning cannot depend on the bundle that did not load.
    def ruact_vite_down_warning
      server = Ruact.config.vite_dev_server.chomp("/")
      message = "The Vite dev server is not running (#{server}), so this page has no JavaScript " \
                "and its React components cannot render. Start the app with bin/dev, which runs " \
                "Rails and Vite together."
      Rails.logger&.warn("[ruact] #{message}")
      <<~HTML.strip
        <div role="alert" data-ruact-vite-down style="position:fixed;inset:0 0 auto 0;z-index:2147483647;padding:12px 16px;background:#7f1d1d;color:#fff;font:14px/1.4 system-ui,sans-serif">
          <strong>[ruact]</strong> #{ERB::Util.html_escape(message)}
        </div>
      HTML
    end

    # The Vite dev-server URL for the virtual bootstrap. Vite serves virtual
    # modules under `/@id/`, encoding the resolved id's leading NUL (`\0`) as
    # `__x00__` — so `\0virtual:ruact/bootstrap` is served at
    # `/@id/__x00__virtual:ruact/bootstrap`. A plain `/virtual:...` URL falls
    # through to the dev server's HTML fallback, so this encoding is required.
    def ruact_bootstrap_dev_url
      "#{Ruact.config.vite_dev_server.chomp('/')}/@id/__x00__#{Ruact.bootstrap_virtual_id}"
    end

    # Probe the CONFIGURED dev server (host:port parsed from
    # `Ruact.config.vite_dev_server`), not a hardcoded localhost:5173 — so a
    # custom `vite_dev_server` and the emitted dev `<script>` URLs always agree
    # on whether the server is up.
    def vite_dev_running?
      require "socket"
      require "uri"
      uri = URI.parse(Ruact.config.vite_dev_server)
      Socket.tcp(uri.host || "localhost", uri.port || 5173, connect_timeout: 1).close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
      false
    end

    # Memoized FOR THE DURATION OF ONE RENDER, which is what lets
    # `ruact_head_assets` and `ruact_js_assets` promise they describe the same
    # build. They are separate calls in the template, so without this a deploy
    # landing between them serves one build's stylesheet beside another build's
    # script — verified reachable in review, not hypothetical.
    def vite_manifest_entry(src_path)
      @__ruact_manifest_entries ||= {}
      return @__ruact_manifest_entries[src_path] if @__ruact_manifest_entries.key?(src_path)

      @__ruact_manifest_entries[src_path] = read_vite_manifest_entry(src_path)
    end

    def read_vite_manifest_entry(src_path)
      manifest_path = Rails.root.join("public", "assets", ".vite", "manifest.json")
      return nil unless File.exist?(manifest_path)

      JSON.parse(File.read(manifest_path))[src_path]
    end
  end
end
