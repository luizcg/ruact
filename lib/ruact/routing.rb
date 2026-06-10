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
  # {Ruact::ConfigurationError} at route-draw time; two query classes mounting
  # the same method name collide on the route NAME and fail Rails' own
  # duplicate-name check — both are loud boot failures, never request-time
  # surprises.
  module Routing
    # Draws the named GET routes for one or more {Ruact::Query} subclasses.
    #
    # @param query_classes [Array<Class>] `Ruact::Query` subclasses to mount.
    # @return [void]
    def ruact_queries(*query_classes)
      # `@set` is the RouteSet this Mapper draws into — passed along so the
      # flatten-collision check can inspect the CURRENT route table (stable
      # Mapper internal across the supported Rails 7.0–8.x matrix).
      query_classes.each { |query_class| Ruact::Routing.draw_query_routes(self, @set, query_class) }
      nil
    end

    class << self
      # @api private — the macro body, kept off the Mapper instance so the only
      # method `ruact_queries` adds to the routing DSL surface is itself.
      def draw_query_routes(mapper, route_set, query_class)
        check_flatten_collision!(route_set, query_class)
        ServerFunctions::QueryDispatch.controller_for(query_class)
        target = ServerFunctions::QueryDispatch.route_target_for(query_class)
        prefix = Ruact.config.query_route_prefix

        query_class.public_instance_methods(false).each do |query_method|
          js_identifier = ServerFunctions::NameBridge.to_js_identifier(query_method)
          mapper.get("#{prefix}/#{js_identifier}",
                     to: "#{target}##{query_method}",
                     as: :"ruact_query_#{js_identifier}")
        end
      end

      private

      # Review rounds 1–3 — namespace flattening means two DISTINCT classes
      # can map to one generated controller constant (`Admin::CatalogQuery`
      # and `AdminCatalogQuery` both → `AdminCatalogQueryController`); the
      # later mount would overwrite the constant and silently cross-wire the
      # earlier class's routes. Detection is STRUCTURAL (round 3 — no ledger
      # to scope or poison): the generated controller is stamped with the
      # query-class name that owns it, and a collision exists only when the
      # constant is owned by a DIFFERENT class AND the route set being drawn
      # into still carries live routes targeting it. That catches collisions
      # across any number of draw/append/prepend blocks and engines on the
      # same RouteSet, while a dev-reload redraw (`clear!` + re-eval) empties
      # the set first — so renaming or removing a query class between reloads
      # is never rejected against a stale owner (D2's reload contract).
      def check_flatten_collision!(route_set, query_class)
        dispatch = ServerFunctions::QueryDispatch
        const_name = dispatch.controller_const_name(query_class)
        return unless dispatch.const_defined?(const_name, false)

        existing = dispatch.const_get(const_name, false)
        owner = existing.respond_to?(:__ruact_query_class_name) ? existing.__ruact_query_class_name : nil
        return if owner.nil? || owner == query_class.name

        target = dispatch.route_target_for(query_class)
        return unless route_set.routes.any? { |route| route.defaults[:controller] == target }

        raise Ruact::ConfigurationError,
              "ruact_queries: #{query_class.name} and #{owner} both flatten to the generated " \
              "dispatch controller Ruact::ServerFunctions::QueryDispatch::#{const_name} — " \
              "rename one of the query classes so their namespace-flattened names differ."
      end
    end
  end
end

# D8 — installed at require time (the Railtie requires this file from its
# `ruact.load_controller` initializer; a direct `require "ruact/routing"`
# in a non-Railtie context gets the same one-shot, idempotent install).
ActionDispatch::Routing::Mapper.include(Ruact::Routing)
