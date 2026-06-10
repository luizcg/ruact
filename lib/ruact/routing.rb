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
      query_classes.each { |query_class| Ruact::Routing.draw_query_routes(self, query_class) }
      nil
    end

    class << self
      # @api private — the macro body, kept off the Mapper instance so the only
      # method `ruact_queries` adds to the routing DSL surface is itself.
      def draw_query_routes(mapper, query_class)
        check_flatten_collision!(mapper, query_class)
        ServerFunctions::QueryDispatch.controller_for(query_class)
        target = ServerFunctions::QueryDispatch.route_target_for(query_class)
        prefix = Ruact.config.query_route_prefix

        query_class.public_instance_methods(false).each do |query_method|
          js_identifier = ServerFunctions::NameBridge.to_js_identifier(query_method)
          mapper.get("#{prefix}/#{js_identifier}",
                     to: "#{target}##{query_method}",
                     as: :"ruact_query_#{js_identifier}")
        end

        claim_flatten_ownership!(mapper, query_class)
      end

      private

      # Review rounds 1–2 — namespace flattening means two DISTINCT classes
      # can map to one generated controller constant (`Admin::CatalogQuery`
      # and `AdminCatalogQuery` both → `AdminCatalogQueryController`), which
      # would silently cross-wire the earlier class's routes. The ownership
      # ledger lives ON the draw's Mapper instance — Rails builds a fresh
      # Mapper per draw-block evaluation, so every redraw starts clean
      # (renaming or removing a query class between dev reloads can never be
      # rejected against a stale owner), and ownership is only committed AFTER
      # the controller generation + route draw succeed (a failed build cannot
      # poison the ledger). Scope = one draw block, which is where all of a
      # host's `ruact_queries` mounts live.
      def check_flatten_collision!(mapper, query_class)
        const_name = ServerFunctions::QueryDispatch.controller_const_name(query_class)
        owner = flatten_ownership_ledger(mapper)[const_name]
        return if owner.nil? || owner == query_class.name

        raise Ruact::ConfigurationError,
              "ruact_queries: #{query_class.name} and #{owner} both flatten to the generated " \
              "dispatch controller Ruact::ServerFunctions::QueryDispatch::#{const_name} — " \
              "rename one of the query classes so their namespace-flattened names differ."
      end

      def claim_flatten_ownership!(mapper, query_class)
        const_name = ServerFunctions::QueryDispatch.controller_const_name(query_class)
        flatten_ownership_ledger(mapper)[const_name] = query_class.name
      end

      def flatten_ownership_ledger(mapper)
        mapper.instance_variable_get(:@__ruact_query_const_owners) ||
          mapper.instance_variable_set(:@__ruact_query_const_owners, {})
      end
    end
  end
end

# D8 — installed at require time (the Railtie requires this file from its
# `ruact.load_controller` initializer; a direct `require "ruact/routing"`
# in a non-Railtie context gets the same one-shot, idempotent install).
ActionDispatch::Routing::Mapper.include(Ruact::Routing)
