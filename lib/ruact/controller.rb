# frozen_string_literal: true

require "json"
require "socket"
require "uri"

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

    # Story 8.1 — class-level DSL surface. The `ruact_action` macro registers
    # a server-callable symbol with `Ruact.action_registry` (so the Vite-plugin
    # codegen from Story 8.0a picks it up at the next `config.to_prepare`) AND
    # defines a matching instance method so the block is reachable from inside
    # other controller code without going through the HTTP endpoint.
    #
    # Validation (naming-bridge rule + within-registry / cross-registry
    # collision detection) fires from {Ruact::ServerFunctions::Registry#register}
    # at controller-class load time — the failure is loud at boot, not at
    # request-dispatch time.
    class_methods do
      # @param symbol [Symbol] the action name (snake_case; bridged to JS
      #   camelCase by {Ruact::ServerFunctions::NameBridge}).
      # @yield [params] the block runs via `instance_exec` on a fresh
      #   controller instance at dispatch time; `params` shadows the request's
      #   `params` accessor and is an `ActionController::Parameters` instance
      #   wrapping the action-call arguments (NOT the request's query/form params).
      # @return [Ruact::ServerFunctions::RegistryEntry] the entry just registered.
      # @raise [Ruact::ConfigurationError] when the symbol fails the
      #   naming-bridge rule or collides with another `ruact_action` in this
      #   registry (cross-registry collisions with `ruact_query` are caught
      #   later by {Ruact::ServerFunctions::Snapshot.functions_payload}).
      def ruact_action(symbol, &block)
        unless block
          raise ArgumentError,
                "ruact_action :#{symbol} requires a block — declare the " \
                "implementation with `ruact_action :#{symbol} do |params| ... end`"
        end

        Ruact.action_registry.register(symbol, kind: :action, controller: self, &block)
        define_method(symbol, &block)
        private(symbol)

        # Dispatcher entry point. `Ruact::ServerFunctions::EndpointController`
        # delegates to `host_controller.dispatch("__ruact_action_<name>",
        # request, response)`; that runs the full ActionController callback
        # chain (before_action, around_action, etc.) and ends here. The wrapper
        # reads the action-call args from the request body (shadowing the
        # request's own `params`) and renders the block's return value as
        # JSON unless the block / a before_action already rendered.
        #
        # The wrapper is PUBLIC because `ActionController#process` only
        # dispatches to methods present in `action_methods` (the controller's
        # public-method set minus a few framework methods). Devs are not
        # expected to call `__ruact_action_<name>` directly; the
        # double-underscore prefix is the social contract.
        wrapper_name = "__ruact_action_#{symbol}"
        define_method(wrapper_name) do
          args = ruact_action_params
          result = __send__(symbol, args)
          render(json: result) unless performed?
        end

        # ActionController caches `action_methods` lazily; clear the cache so
        # the newly-defined wrapper is dispatchable in the same boot cycle
        # (matters in tests and in dev where `ruact_action` declarations
        # accumulate after the controller class first loads).
        clear_action_methods! if respond_to?(:clear_action_methods!, true)
      end
    end

    private

    # Story 8.1 — extracts the action-call arguments from the request body for
    # a `ruact_action` invocation. The result becomes the `params` block-arg
    # the dev wrote in `ruact_action :foo do |params| ... end`, shadowing the
    # request's own `params` accessor. Returns an `ActionController::Parameters`
    # so `params.require(:title).permit(...)` continues to work inside the block.
    #
    # Wire shape (from the JS runtime):
    #   - `Content-Type: application/json` → `JSON.parse(request.body)` as a Hash
    #   - `Content-Type: multipart/form-data` or `application/x-www-form-urlencoded`
    #     → Rails has already parsed `request.request_parameters` for us
    #   - Other / missing → empty Hash (callers must validate themselves)
    def ruact_action_params
      raw = ruact_action_raw_args
      ActionController::Parameters.new(raw)
    end

    def ruact_action_raw_args
      content_type = request.content_mime_type&.to_s ||
                     request.headers["Content-Type"]&.split(";")&.first
      case content_type
      when "application/json"
        body = request.body.read
        request.body.rewind if request.body.respond_to?(:rewind)
        return {} if body.nil? || body.empty?
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : { "_value" => parsed }
      when "multipart/form-data", "application/x-www-form-urlencoded"
        request.request_parameters.except(:name, :action, :controller)
      else
        {}
      end
    rescue JSON::ParserError
      {}
    end

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
end
