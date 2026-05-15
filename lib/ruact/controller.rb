# frozen_string_literal: true

require "json"
require "set"
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

    # Story 8.1 review-batch 1 (2026-05-14) — symbols a host MUST NOT use
    # as `ruact_action` / `ruact_query` names because overriding them
    # would corrupt request handling. Keep sorted; documented per name:
    # `:params`, `:request`, `:response`, `:headers`, `:session`, `:flash`,
    # `:cookies` — request/response accessors; overriding breaks reads
    # `:render`, `:redirect_to`, `:head`, `:send_file`, `:send_data` —
    #   response producers; overriding breaks the response path
    # `:action_name`, `:controller_name`, `:controller_path` — routing
    #   identification; overriding breaks `before_action :foo, only:` matching
    # `:url_for`, `:url_options` — URL generation
    # `:dispatch`, `:process`, `:process_action` — Rails dispatch internals
    # `:form_authenticity_token`, `:verified_request?` — CSRF plumbing
    # Re-run-4 (2026-05-15) — list expanded with the additional
    # ActionController instance methods reviewers flagged as silently
    # clobberable: `:render_to_string` / `:render_to_body` (response
    # producers used by templating), `:send_action` (Rails dispatch
    # internal), `:logger` / `:logger=` (clobbering breaks every log
    # statement on the controller), `:default_render` (the gem hook
    # method itself — overriding would disable RSC rendering).
    FRAMEWORK_RESERVED_METHODS = %i[
      __send__ action_name controller_name controller_path cookies
      default_render dispatch flash form_authenticity_token head headers
      instance_eval instance_exec logger logger= method params process
      process_action public_send redirect_to render render_to_body
      render_to_string request response send send_action send_data
      send_file session url_for url_options verified_request?
    ].to_set.freeze

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
        # Re-run-2 (2026-05-14) — `ruact_action` strictly requires a Symbol.
        # A String slips through the naming-bridge regex but stores a
        # String key in `@entries`, while `EndpointController#dispatch_action`
        # looks the entry up by `:name.to_sym` — net effect: silent 404 on
        # every dispatch. Refuse Strings (and anything else) loudly.
        unless symbol.is_a?(Symbol)
          raise ArgumentError,
                "ruact_action requires a Symbol argument, got " \
                "#{symbol.inspect} (#{symbol.class}). Use " \
                "`ruact_action :#{symbol}` not `ruact_action #{symbol.inspect}`."
        end

        unless block
          raise ArgumentError,
                "ruact_action :#{symbol} requires a block — declare the " \
                "implementation with `ruact_action :#{symbol} do |params| ... end`"
        end

        # Re-run-4 (2026-05-15) — parameter-shape guard (replaces the
        # earlier `block.arity` check). `block.arity` is negative for
        # ALL signatures that include any optional/keyword/splat
        # parameter — including footguns like `do |params, required:|`
        # which would crash at dispatch time when the macro invokes the
        # block with one positional argument and no keyword arguments.
        # We use `block.parameters` for full inspection: the block must
        # accept exactly one positional argument (`:req`, `:opt`, or
        # `:rest`) AND have no required keyword parameters (`:keyreq`).
        # Optional keyword params (`:key`) and double-splat (`:keyrest`)
        # are fine.
        positional = block.parameters.count { |kind, _| %i[req opt rest].include?(kind) }
        has_required_kwarg = block.parameters.any? { |kind, _| kind == :keyreq }
        if positional == 0 || has_required_kwarg
          raise ArgumentError,
                "ruact_action :#{symbol} block must accept exactly one " \
                "positional parameter and no required keyword arguments " \
                "(got parameters=#{block.parameters.inspect}). Use " \
                "`ruact_action :#{symbol} do |params| ... end`."
        end

        # Review-batch 1 (2026-05-14) — framework-method-clobber guard.
        # Refuse to define if the symbol matches one of the well-known
        # ActionController instance methods that would corrupt request
        # handling if overridden (the `:params`, `:render`, `:session`,
        # `:redirect_to`, `:dispatch`, etc. footgun). The hardcoded list
        # is the canonical set documented in the Rails Guides; it's used
        # in place of a dynamic `ActionController::Base.method_defined?`
        # check because (a) the gem can be loaded before ActionController
        # (e.g., in a non-Rails context) and (b) the dynamic list would
        # include too many low-risk inherited methods (`:object_id`,
        # `:respond_to?`) and produce confusing error messages.
        if FRAMEWORK_RESERVED_METHODS.include?(symbol)
          raise Ruact::ConfigurationError,
                "ruact_action :#{symbol} would clobber a framework method — " \
                "#{symbol.inspect} is a reserved ActionController instance " \
                "method. Pick a different symbol (e.g. :#{symbol}_action) so " \
                "the host's CSRF / params / render plumbing remains intact."
        end

        # Re-run-2 (2026-05-14) — refuse to clobber a method ALREADY defined
        # on the host controller class itself. Common case: a controller has
        # a normal `def index` action and the dev mistakenly writes
        # `ruact_action :index do ... end`. Pre-batch this silently
        # overrode :index with the action body + thread-local guard — the
        # standard `GET /widgets` would then raise the security guard, since
        # it's not a /__ruact/fn/index call. We check `instance_methods(false)
        # + private_instance_methods(false)` (own class only — inherited
        # framework methods are already caught by FRAMEWORK_RESERVED_METHODS).
        #
        # A method previously defined BY `ruact_action` on this same class
        # is NOT a clobber — re-registration is legitimate (dev-mode reload,
        # test re-registration after registry reset). We track our own
        # define_method calls in `@__ruact_defined_methods` and skip the
        # guard for those.
        @__ruact_defined_methods ||= Set.new
        own_methods = instance_methods(false) + private_instance_methods(false)
        if own_methods.include?(symbol) && !@__ruact_defined_methods.include?(symbol)
          raise Ruact::ConfigurationError,
                "ruact_action :#{symbol} would clobber an existing method " \
                "on #{self.name || self}. If #{symbol.inspect} is meant to be " \
                "a server action, remove the existing definition first; " \
                "if it's a regular controller action, pick a different " \
                "ruact_action symbol (e.g. :#{symbol}_remote)."
        end

        # Re-run-3 (2026-05-15) — refuse to clobber an INHERITED app helper.
        # Common case: `ApplicationController` defines `current_user` /
        # `authenticate_user!` / `authorize` and a subclass mistakenly
        # writes `ruact_action :current_user`. The above own-class check
        # misses these because the method lives on a superclass; the
        # FRAMEWORK_RESERVED_METHODS check misses them because they are
        # app-defined, not part of `ActionController::Base`. Detect by
        # asking the class hierarchy MINUS the ActionController baseline:
        # any method that responds on `self` but NOT on
        # `ActionController::Base` is an app-defined helper inherited
        # from `ApplicationController` (or a concern mixed in there).
        baseline = defined?(ActionController::Base) ? ActionController::Base : nil
        if baseline &&
           (method_defined?(symbol) || private_method_defined?(symbol)) &&
           !(baseline.method_defined?(symbol) || baseline.private_method_defined?(symbol)) &&
           !@__ruact_defined_methods.include?(symbol)
          raise Ruact::ConfigurationError,
                "ruact_action :#{symbol} would clobber an inherited helper " \
                "on #{self.name || self} (likely defined on " \
                "ApplicationController or a concern). Overriding " \
                "#{symbol.inspect} would break callers that rely on it — " \
                "pick a different ruact_action symbol (e.g. :#{symbol}_remote)."
        end

        Ruact.action_registry.register(symbol, kind: :action, controller: self, &block)

        # Review-batch 1 (2026-05-14) — define `<symbol>` directly (no
        # separate `__ruact_action_*` wrapper). This makes `before_action
        # :foo, only: :create_post` match the actual action name. The
        # method is public so `ActionController#process` dispatches to it
        # through the standard callback chain.
        #
        # Defense in depth: the method body raises unless invoked under the
        # gem's endpoint dispatch path (a thread-local sentinel set by
        # `Ruact::ServerFunctions::EndpointController#dispatch_action`).
        # Without the sentinel, a wildcard route like `get ":controller/
        # :action"` could otherwise reach `create_post` as a GET (no CSRF).
        @__ruact_defined_methods << symbol
        define_method(symbol) do
          unless Thread.current[:__ruact_dispatching] == symbol
            raise Ruact::Error,
                  "ruact action :#{symbol} can only be invoked through " \
                  "POST /__ruact/fn/:name. Direct method calls or wildcard " \
                  "routes are rejected for security reasons."
          end
          begin
            args = ruact_action_params
          rescue JSON::ParserError => e
            # Re-run-4 (2026-05-15) — return a structured 400 instead of
            # surfacing the raw `JSON::ParserError`. The host's
            # `rescue_from` chain may not have a handler for it (Rails'
            # default is a 500), and even when it does the response
            # shape is not the bad-request contract the JS runtime
            # expects (`{error}` JSON body + 400 status).
            return render(
              json: { error: "ruact action :#{symbol} received malformed JSON body: #{e.message}" },
              status: :bad_request
            )
          end
          result = instance_exec(args, &block)
          return if performed?
          # AC2: a nil block return renders 204 No Content (no body). A non-nil
          # return renders 200 + JSON.
          if result.nil?
            head(:no_content)
          else
            render(json: result)
          end
        end

        # ActionController caches `action_methods` lazily; clear the cache so
        # the newly-defined action is dispatchable in the same boot cycle
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
        # Re-run-3 (2026-05-15) — use `request.raw_post` instead of
        # `request.body.read`. Rack caches `raw_post` after the first
        # read of the request body, so a host `before_action` that
        # already touched `request.body` would otherwise leave the
        # IO at EOF and our `.read` would return `""` — silently
        # coercing the action call to an empty hash. `raw_post` is
        # safe to call multiple times and returns the full POST body.
        body = request.raw_post
        return {} if body.nil? || body.empty?
        # Review-batch 2 (2026-05-14) — raise on malformed JSON instead of
        # silently coercing to {}. A request with `Content-Type:
        # application/json` and an unparseable body is corrupted; running
        # the action on `{}` would mask real client bugs. Rails' standard
        # 400 handler surfaces this as a clean error response.
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : { "_value" => parsed }
      when "multipart/form-data", "application/x-www-form-urlencoded"
        # Review-batch 2 (2026-05-14) — `request.request_parameters` is the
        # POST body ONLY (routing params like `:name`, `:action`,
        # `:controller` live in `request.path_parameters`, NOT here). The
        # earlier `.except(:name, :action, :controller)` was a bug — it
        # would silently drop legitimate body fields named `name`,
        # `action`, or `controller` from forms.
        request.request_parameters
      else
        {}
      end
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
