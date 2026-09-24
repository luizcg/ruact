# frozen_string_literal: true

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
      def native_response
        [200,
         { HEADER => NATIVE, "content-type" => "text/plain; charset=utf-8",
           "cache-control" => "no-store", "vary" => "Ruact-Request" },
         []]
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
        verdict_in(@router || Rails.application.routes.router, request)
      rescue StandardError
        :pass
      end

      private

      def verdict_in(router, request)
        router.recognize(request) do |route, params|
          app = route.app
          if app.is_a?(ActionDispatch::Routing::Mapper::Constraints)
            request.path_parameters = params
            next unless app.matches?(request) # `serve` would cascade to the next route

            app = app.app
          end

          return verdict_for(route, app, request, params)
        end
        :pass # no route: the 404 goes the normal way
      end

      def verdict_for(route, app, request, params)
        return action_verdict(request, params[:controller], params[:action]) if route.dispatcher?
        # The fetch follows the redirect and the target is classified on arrival.
        return :pass if app.is_a?(ActionDispatch::Routing::Redirect)
        return engine_verdict(app, request) if app.respond_to?(:routes) && app.routes.respond_to?(:router)

        :native # a mounted Rack app renders no ruact page
      end

      # Inside `recognize`'s block the request's path_info is already relative
      # to the mount point, which is what the engine's own router expects.
      def engine_verdict(engine, request)
        verdict_in(engine.routes.router, request)
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
      def action_verdict(request, controller, action)
        klass = "#{controller.to_s.camelize}Controller".safe_constantize
        return :pass unless klass.is_a?(Class)
        return :native unless klass.include?(Ruact::Controller)
        return :ruact unless request.get? || request.head?

        klass.ruact_page?(action) ? :ruact : :native
      end
    end
  end
end
