# frozen_string_literal: true

require "action_dispatch"

module Ruact
  # Story 9.4 (D8) — the `ruact_queries` routing macro. Included into
  # `ActionDispatch::Routing::Mapper` by the Railtie, so it is available
  # inside `Rails.application.routes.draw`:
  #
  #   Rails.application.routes.draw do
  #     ruact_queries CatalogQuery        # GET /q/categories, GET /q/searchUsers, …
  #     resources :posts
  #   end
  #
  # For each `public_instance_methods(false)` of the query class — methods
  # inherited from `Ruact::Query` / `ApplicationQuery` or mixed in from user
  # modules are NOT mounted (AC1) — one NAMED GET route is drawn at
  # `GET <Ruact.config.query_route_prefix>/<jsIdentifier>` (default `/q`,
  # contract decision #7), pointing at the query class's generated internal
  # dispatch controller ({Ruact::ServerFunctions::QueryDispatch}). Every query
  # is visible in `rails routes` — no hidden endpoint; the route table stays
  # the single source of truth.
  #
  # The path segment reuses {Ruact::ServerFunctions::NameBridge} verbatim
  # (D4): `def search_users` → `GET /q/searchUsers`, named
  # `ruact_query_searchUsers`. Invalid or JS-reserved method names raise
  # {Ruact::ConfigurationError} at route-draw time, and so do two query
  # classes mounting the same method name (they would collide on the route
  # name and on the export) — both are loud boot failures, never request-time
  # surprises.
  #
  # The generated dispatch controller PRESERVES the query class's namespace
  # (review round 4) — `Admin::CatalogQuery` →
  # `Ruact::ServerFunctions::QueryDispatch::Admin::CatalogQueryController` — so
  # the controller constant is an injective function of the query class's
  # fully-qualified name: two distinct query classes can never map to the same
  # constant, and there is no flatten collision to detect (across any number
  # of RouteSets / mounted engines sharing the global dispatch namespace).
  module Routing
    # Draws the named GET routes for one or more {Ruact::Query} subclasses.
    #
    # @param query_classes [Array<Class>] `Ruact::Query` subclasses to mount.
    # @return [void]
    def ruact_queries(*query_classes)
      query_classes.each { |query_class| Ruact::Routing.draw_query_routes(self, query_class) }
      nil
    end

    class << self
      # @api private — the macro body, kept off the Mapper instance so the only
      # method `ruact_queries` adds to the routing DSL surface is itself.
      def draw_query_routes(mapper, query_class)
        ServerFunctions::QueryDispatch.controller_for(query_class)
        target = ServerFunctions::QueryDispatch.route_target_for(query_class)
        prefix = Ruact.config.query_route_prefix

        query_class.public_instance_methods(false).each do |query_method|
          js_identifier = ServerFunctions::NameBridge.to_js_identifier(query_method)
          begin
            mapper.get("#{prefix}/#{js_identifier}",
                       to: "#{target}##{query_method}",
                       as: :"ruact_query_#{js_identifier}")
          rescue ArgumentError => e
            raise unless e.message.include?("already in use")

            raise_query_name_taken!(query_class, query_method, "#{prefix}/#{js_identifier}")
          end
        end
      end

      # Rails' own message ("Invalid route name, already in use") names a route
      # the app never wrote. Name the query, the method and the way out.
      def raise_query_name_taken!(query_class, query_method, path)
        raise Ruact::ConfigurationError,
              "#{query_class}##{query_method} cannot be mounted: GET #{path} is already mounted " \
              "in these routes — by another query class that also defines `#{query_method}`, or " \
              "by `ruact_queries #{query_class}` appearing twice. Query names share one namespace " \
              "(one route and one export of @/.ruact/server-functions per name): remove the " \
              "duplicate mount, or rename one of the methods (the scaffold names its search " \
              "after the resource: search_posts, search_comments)."
      end
    end
  end
end

# D8 — installed at require time (the Railtie requires this file from its
# `ruact.load_controller` initializer; a direct `require "ruact/routing"`
# in a non-Railtie context gets the same one-shot, idempotent install).
# Written as a class reopening (rather than
# `ActionDispatch::Routing::Mapper.include Ruact::Routing`) so YARD's static
# MixinHandler resolves the named namespace instead of choking on the external
# constant receiver under `--fail-on-warning`.
module ActionDispatch # rubocop:disable Style/OneClassPerFile -- deliberate Mapper extension install (D8)
  module Routing
    class Mapper
      include Ruact::Routing
    end
  end
end
