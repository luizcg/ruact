# frozen_string_literal: true

require "uri"

module Ruact
  # Story 17.0f (FR117) — the document belongs to whoever rendered it.
  #
  # The ruact router intercepts every same-origin link and form: it cannot know,
  # from the browser, whether the destination is a ruact page. Asked with
  # `Accept: text/x-component`, an ordinary Rails action answers 200 HTML, which
  # the router cannot render — a dead click, silently (spike 2026-09-12, S2). And
  # a form that crossed to an ordinary action had already RUN it by the time the
  # router saw the HTML, so it could not be retried (S9b).
  #
  # The server can know, before anything runs. For a request the router sent
  # (`Ruact-Request: 1`, a header only the router sends), {Middleware} asks
  # {Classifier} whether the route it would reach is a ruact page. If not, it
  # answers `Ruact-Boundary: native` WITHOUT calling the app, and the router
  # hands the navigation — or the form submission — to the browser. The action
  # then runs exactly once, natively, and its real response (a 422 with the
  # validation errors included) reaches the user.
  #
  # Measured in the 2026-09-16 spike (playgrounds/nav-islands): ~0.1 ms median
  # per router request; every fixture below held.
  module NavigationBoundary
    # Response header the router reads.
    HEADER = "ruact-boundary"
    # Its only value today: "not a ruact page — let the browser do it".
    NATIVE = "native"

    # The Rack middleware the Railtie installs. Remove it with
    # `config.middleware.delete Ruact::NavigationBoundary::Middleware`.
    class Middleware
      def initialize(app, classifier: Classifier.new)
        @app = app
        @classifier = classifier
      end

      def call(env)
        return @app.call(env) unless env["HTTP_RUACT_REQUEST"] == "1"
        return native_response if @classifier.classify(env) == :native

        @app.call(env)
      end

      private

      # `Vary`, because the same URL answers differently with and without the
      # router's header; `no-store`, because this answer is about routing, not
      # content, and must never be served from a cache to a browser navigation.
      #
      # Built through Rack's own header class so a later middleware looking up
      # `Cache-Control` finds this one on Rack 2 (Rails 7.0) as well as Rack 3.
      def native_response
        [200, native_headers, []]
      end

      def native_headers
        headers = defined?(Rack::Headers) ? Rack::Headers.new : Rack::Utils::HeaderHash.new
        headers[HEADER] = NATIVE
        headers["content-type"] = "text/plain; charset=utf-8"
        headers["cache-control"] = "no-store"
        headers["vary"] = "Ruact-Request"
        headers
      end
    end

    # Decides, from the route table alone, where a request would land.
    #
    # Mirrors what Rails' own router does on `serve` — not just `recognize`:
    # lambda and object constraints are evaluated IN ROUTE ORDER, with the same
    # cascade to the next matching route (`recognize` alone skips them; they
    # live on `Mapper::Constraints` and only run on `serve`). Descends into
    # mounted engines. Nothing it calls executes an action.
    #
    # Ties break towards letting the request through: a wrong :native would
    # skip ruact on a ruact page, a wrong :ruact would bring the dead click back,
    # but :pass only costs what ruact cost before this existed.
    class Classifier
      # @param router [ActionDispatch::Journey::Router, nil] defaults to the
      #   application's, resolved lazily (routes reload in development)
      def initialize(router = nil)
        @router = router
      end

      # @param env [Hash] the Rack env
      # @return [Symbol] `:ruact`, `:native`, or `:pass` (could not tell)
      def classify(env)
        request = ActionDispatch::Request.new(env.dup)
        verdict_in(@router || application_router, request) || :pass
      rescue Ruact::ConfigurationError => e
        # A misdeclared `ruact_pages` is the app's bug to see, not a routing
        # doubt: say so where it shows, then let the request through.
        Rails.logger&.warn("[ruact] #{e.message}")
        :pass
      rescue StandardError => e
        Rails.logger&.debug do
          "[ruact] navigation boundary could not classify #{env['PATH_INFO']}: #{e.class}: #{e.message}"
        end
        :pass
      end

      private

      # Rails 8 routes load lazily in development and test: the route set loads
      # itself on `call`, but not when its `router` is read — and this runs
      # BEFORE the app is called, so the first request after a boot could see
      # an empty table.
      def application_router
        app = Rails.application
        app.reload_routes_unless_loaded if app.respond_to?(:reload_routes_unless_loaded)
        app.routes.router
      end

      # @return [Symbol, nil] nil when nothing in THIS router answers — the
      #   caller keeps scanning, the way Rails cascades past an engine (or a Rack
      #   app at "/") whose own routes do not match
      def verdict_in(router, request, in_engine: false)
        root_app = false
        router.recognize(request) do |route, params|
          app = route.app
          if app.is_a?(ActionDispatch::Routing::Mapper::Constraints)
            request.path_parameters = params
            next unless app.matches?(request) # `serve` would cascade to the next route

            app = app.app
          end

          if mounted_rack_app?(route, app)
            # A Rack app mounted at "/" (Grape, Sinatra) passes on what it does
            # not know with `X-Cascade: pass`, and Rails moves on: keep looking.
            # Mounted anywhere else, it owns its prefix — Sidekiq at /sidekiq is
            # not reclassified by a catch-all route drawn after it.
            if route.path.spec.to_s == "/"
              root_app = true
              next
            end
            return :native
          end

          verdict = verdict_for(route, app, request, params, in_engine: in_engine)
          return verdict if verdict # an engine with no matching route cascades: keep looking
        end
        root_app ? :native : nil
      end

      def mounted_rack_app?(route, app)
        !route.dispatcher? && !app.is_a?(ActionDispatch::Routing::Redirect) && !engine?(app)
      end

      def engine?(app)
        app.respond_to?(:routes) && app.routes.respond_to?(:router)
      end

      def verdict_for(route, app, request, params, in_engine:)
        return action_verdict(request, params[:controller], params[:action], in_engine) if route.dispatcher?
        # A route that redirects answers the router itself; there is no "no
        # match" for it, so an unclassifiable one passes rather than cascading.
        return redirect_verdict(app, request, params) || :pass if app.is_a?(ActionDispatch::Routing::Redirect)

        # Inside `recognize`'s block the request's path_info is already relative
        # to the mount point, which is what the engine's own router expects.
        verdict_in(app.routes.router, request, in_engine: true)
      end

      # Same origin: the fetch follows the redirect and the target is
      # classified when it arrives. Another origin: the fetch cannot follow it
      # (CORS), so the browser has to — native.
      #
      # A 307/308 on a form re-sends the POST to the target; if that target is
      # not ruact, the router could only answer with a GET there and the POST
      # would never run. The browser's own submit follows it correctly: native.
      #
      # A `redirect { |params, req| … }` BLOCK is application code — it may
      # query the database — and is never run here: it passes through.
      EVALUATED_REDIRECTS = %w[ActionDispatch::Routing::PathRedirect ActionDispatch::Routing::OptionRedirect].freeze
      private_constant :EVALUATED_REDIRECTS

      def redirect_verdict(redirect, request, params)
        return :native if [307, 308].include?(redirect.status) && !(request.get? || request.head?)
        return :pass unless EVALUATED_REDIRECTS.include?(redirect.class.name)

        target = URI.parse(redirect.path(params, request).to_s)
        same_origin = target.host == request.host && (target.port || request.port) == request.port
        return :pass if target.host.nil? || same_origin

        :native
      rescue StandardError
        :pass
      end

      # GET/HEAD: ruact renders the page only when `default_render` would —
      # the same class-level predicate, never a copy of it. That is what keeps a
      # Devise-like controller (it inherits the app's ruact controller, its
      # templates live in the engine) native.
      #
      # Anything else: including the concern is enough. A `create` has no
      # template, and answers the router with a Flight redirect row
      # (Ruact::Controller#redirect_to) — the Story 13.3 redirect-back has to
      # stay in place, not become a full page load.
      #
      # Inside a mounted ENGINE, a non-GET is native even when its controller
      # inherits the app's ruact controller: that is Devise's shape, and its
      # `destroy` answers a non-navigational request with a bare 204 — the user
      # is signed out and the router has nothing to render. An engine's actions
      # speak the engine's protocol, not ruact's. Its GET pages still count when
      # the APP provides the template (the way apps override engine views).
      #
      # The same holds for a controller a GEM defines even when its routes are
      # drawn into the app's own table — `devise_for` mounts no engine, and
      # `Devise::SessionsController#destroy` is the sign-out the rule exists
      # for. So a non-GET is ruact only when the controller is the app's own:
      # defined under `Rails.root/app`.
      def action_verdict(request, controller, action, in_engine)
        klass = "#{controller.to_s.camelize}Controller".safe_constantize
        return :pass unless klass.is_a?(Class)
        return :native unless klass.include?(Ruact::Controller)
        return non_get_verdict(klass, action, in_engine) unless request.get? || request.head?

        klass.ruact_page?(action) ? :ruact : :native
      end

      # Story 17.0g — a controller that DECLARED its pages (`ruact_pages`) is ruact
      # only for those: a `create` whose `new` is a plain Rails page re-renders
      # plain HTML on a validation error, which the router could not show.
      def non_get_verdict(klass, action, in_engine)
        return :native if in_engine || !app_owned?(klass)
        return :native if klass.__ruact_pages && !klass.ruact_page_action?(action)

        :ruact
      end

      def app_owned?(klass)
        file = Object.const_source_location(klass.name)&.first
        !file.nil? && File.expand_path(file).start_with?("#{Rails.root.join('app')}/")
      end
    end
  end
end
