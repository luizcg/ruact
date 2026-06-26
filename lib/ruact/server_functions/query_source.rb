# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "ruact/server_functions/name_bridge"

module Ruact
  module ServerFunctions
    # Story 9.5 — derives v2 QUERY entries for the route-driven codegen, the
    # read-side sibling of {RouteSource} (which derives the non-GET mutation
    # actions). Queries come from {Ruact::Query} subclasses mounted via the
    # `ruact_queries` routing macro (Story 9.4).
    #
    # ## Why read the drawn route table, not all Ruact::Query subclasses
    #
    # The route table is the single source of truth (FR61): a host exposes a
    # query ONLY by mounting its class with `ruact_queries` in `routes.rb`.
    # Enumerating every `Ruact::Query` subclass would over-expose query classes
    # that are defined but never mounted (and would 404 when `useQuery` fetched
    # their non-existent routes). Reading the routes the `ruact_queries` macro
    # actually drew keeps codegen route-truth-consistent with dispatch by
    # construction — and means there is no `app/queries` force-load gap to
    # paper over (mounting a class in `routes.rb` already autoloads it).
    #
    # Every generated query dispatch controller lives under the
    # {QUERY_CONTROLLER_PREFIX} namespace (see
    # {QueryDispatch.route_target_for}), so the GET routes this module consumes
    # are unambiguous: any drawn route whose controller path starts with that
    # prefix is a mounted query method.
    #
    # Pure by construction: {.collect} takes the route set and a resolver
    # callable (controller-path → the backing {Ruact::Query} subclass). The
    # railtie passes the real constant-resolving implementation; unit specs
    # inject a lambda so the derivation is testable without booting controllers.
    #
    # @see RouteSource the mutation (action) sibling
    # @see Ruact::Routing#ruact_queries the macro that draws the routes read here
    module QuerySource
      # The controller-path prefix every generated query dispatch controller
      # lives under (mirrors {QueryDispatch.route_target_for}). A drawn GET
      # route whose controller starts with this prefix is a mounted query.
      QUERY_CONTROLLER_PREFIX = "ruact/server_functions/query_dispatch/"

      # `Method#parameters` types that mark keyword arguments — the FR88 query
      # parameters (mirrors {QueryDispatch::Dispatching::KEYWORD_PARAM_TYPES}).
      KEYWORD_PARAM_TYPES = %i[key keyreq keyrest].freeze

      class << self
        # Collects v2 query entries from +route_set+.
        #
        # @param route_set [#routes] anything exposing `#routes` (an
        #   `ActionDispatch::Routing::RouteSet`, or `Rails.application.routes`).
        # @param query_class_for [#call, nil] `controller_path(String) ->
        #   (Class | nil)` — resolves a query dispatch controller path to the
        #   {Ruact::Query} subclass it backs. Defaults to real constant
        #   resolution (reads the generated controller's `__ruact_query_class`).
        # @return [Array<Hash>] query entries (string keys) sorted by
        #   `js_identifier`; shape: `js_identifier`, `kind` (always `"query"`),
        #   `http_method` (always `"GET"`), `path`, `segments` (always `[]`),
        #   `accepts_params` (Boolean — does the method declare kwargs?),
        #   `params` (Array<Hash> — Story 13.4: one `{ "name" => String,
        #   "required" => Boolean }` per declared `keyreq`/`key` keyword, in
        #   declaration order; empty when none), `params_rest` (Boolean —
        #   Story 13.4: does the method declare a `**keyrest`?),
        #   `controller` (the query class name — for collision origins),
        #   `action` (the Ruby method name).
        # @raise [Ruact::ConfigurationError] on a query×query naming collision.
        def collect(route_set, query_class_for: nil)
          query_class_for ||= method(:default_query_class_for)

          entries = []
          route_set.routes.each do |route|
            controller = route.defaults[:controller]
            action = route.defaults[:action]
            next if controller.nil? || action.nil?
            next unless controller.to_s.start_with?(QUERY_CONTROLLER_PREFIX)

            query_class = query_class_for.call(controller.to_s)
            next if query_class.nil?

            entries << build_entry(route, action.to_s, query_class)
          end

          entries = entries.sort_by { |entry| entry["js_identifier"] }
          detect_collisions!(entries)
          entries
        end

        private

        def build_entry(route, action, query_class)
          params, params_rest = param_metadata(query_class, action)
          {
            "js_identifier" => NameBridge.to_js_identifier(action),
            "kind" => "query",
            "http_method" => "GET",
            "path" => clean_path(route),
            "segments" => [],
            # Story 13.4 — keep `accepts_params` (derived) for back-compat: any
            # named kwarg OR a `**keyrest` means the accessor takes params.
            "accepts_params" => !params.empty? || params_rest,
            "params" => params,
            "params_rest" => params_rest,
            "controller" => query_class.name,
            "action" => action
          }
        end

        # Story 13.4 — per-kwarg metadata driving the typed TS `params` object
        # (AC1). Reflects `Method#parameters` (names + required/optional only —
        # Ruby exposes no types/defaults): `:keyreq` → required prop, `:key` →
        # optional prop (both in declaration order, the stable order
        # `parameters` returns), `:keyrest` (`**opts`) → an open-record marker
        # so a legitimate dynamic key is never narrowed away (fail open).
        # Positional/block params are not FR88 query params and are ignored.
        #
        # @param query_class [Class]
        # @param action [String]
        # @return [Array(Array<Hash>, Boolean)] the per-kwarg descriptors and
        #   whether a `**keyrest` is present.
        def param_metadata(query_class, action)
          params = []
          rest = false
          query_class.instance_method(action).parameters.each do |(type, name)|
            next unless KEYWORD_PARAM_TYPES.include?(type)

            if type == :keyrest
              rest = true
            else
              params << { "name" => name.to_s, "required" => type == :keyreq }
            end
          end
          [params, rest]
        rescue NameError
          [[], false]
        end

        # query×query collision — two mounted query classes whose methods map
        # to the SAME JS identifier (e.g. `CatalogQuery#search_users` and
        # `PeopleQuery#search_users`). Fail loudly at boot naming both origins.
        # The route×query side of the merged namespace is detected at the
        # codegen combine point (see {ServerFunctions.write_v2_snapshot!}).
        def detect_collisions!(entries)
          entries.group_by { |entry| entry["js_identifier"] }.each do |js_id, group|
            next if group.size < 2

            origins = group.map { |entry| "#{entry['controller']}##{entry['action']}" }
            raise Ruact::ConfigurationError,
                  "server-function naming collision: #{origins.join(' and ')} " \
                  "both map to JS identifier \"#{js_id}\" — rename one of the query methods."
          end
        end

        # `/q/categories(.:format)` → `/q/categories`. Mirrors
        # {RouteSource#clean_path}: drops the trailing format optional and any
        # remaining optional `( … )` group.
        def clean_path(route)
          spec = route.path.spec.to_s
          spec = spec.delete_suffix("(.:format)")
          spec.gsub(/\([^)]*\)/, "")
        end

        # Real resolver — used in the railtie/rake paths. The generated query
        # dispatch controller exposes `__ruact_query_class` (a singleton method
        # set by {QueryDispatch.controller_for}); resolve the controller
        # constant from its path and read that back.
        def default_query_class_for(controller)
          klass = "#{controller}_controller".camelize.safe_constantize
          return nil unless klass.respond_to?(:__ruact_query_class)

          klass.__ruact_query_class
        rescue StandardError
          nil
        end
      end
    end
  end
end
