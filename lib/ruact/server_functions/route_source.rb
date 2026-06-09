# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "ruact/server_functions/name_bridge"

module Ruact
  module ServerFunctions
    # Story 9.3 — derives v2 server-function entries from the Rails route table.
    #
    # The route table is the single source of truth (FR61): every non-GET routed
    # action on a controller that includes {Ruact::Server} is a callable server
    # function. This module is the route-driven replacement for the v1 registry
    # source consumed by {Ruact::ServerFunctions::Snapshot} — it reads routes,
    # not `ruact_action` declarations.
    #
    # Pure by construction: {.collect} takes the route set and two resolver
    # callables (host predicate + override lookup). The railtie passes the real
    # constant-resolving implementations; unit specs inject lambdas so the
    # derivation table is testable without booting controllers.
    #
    # ## Derivation table (locked, ADR addendum 2026-06-09)
    #
    # `js_identifier = lowerCamel(action) + Namespace*(Pascal) + Resource(Pascal)`
    #
    # - **Resource word** — singular for the RESTful writes (`create`/`update`/
    #   `destroy`) and for any member route (path carries `:id`); plural for a
    #   custom collection route. Examples: `posts#create` → `createPost`,
    #   `posts#publish` (member) → `publishPost`, `posts#publish_all`
    #   (collection) → `publishAllPosts`, `resource :session` `#create` →
    #   `createSession`.
    # - **Namespace** — PascalCased and inserted between verb and resource
    #   (prefix, NOT flat): `admin/posts#create` → `createAdminPost`,
    #   `admin/reports/posts#create` → `createAdminReportsPost`. Prefixing keeps
    #   the merged JS namespace collision-free by construction (a flat scheme
    #   would force `admin/posts#create` and `posts#create` to collide).
    # - **PATCH/PUT** — `resources` emits both verbs for `update`; they collapse
    #   to one entry with `http_method: "PATCH"` (Rails' primary verb).
    #
    # @see docs/internal/decisions/server-functions-api.md "Story 9.3"
    module RouteSource
      # Verbs that expose a callable server function. GET/HEAD are pages.
      MUTATION_VERBS = %w[POST PUT PATCH DELETE].freeze

      # The RESTful writes whose JS name uses the SINGULAR resource even though
      # `create` is technically a collection route.
      RESTFUL_WRITES = %w[create update destroy].freeze

      # When the same controller#action is routed under several verbs (the
      # `update` PATCH/PUT pair), keep the first by this priority.
      VERB_PRIORITY = { "PATCH" => 0, "PUT" => 1, "POST" => 2, "DELETE" => 3 }.freeze

      class << self
        # Collects v2 mutation entries from +route_set+.
        #
        # @param route_set [#routes] anything exposing `#routes` (a
        #   `ActionDispatch::Routing::RouteSet`, or `Rails.application.routes`).
        # @param host_predicate [#call] `controller_path(String) -> Boolean` —
        #   true when that controller includes {Ruact::Server}. Defaults to real
        #   constant resolution.
        # @param overrides_for [#call] `controller_path(String) -> Hash{String=>String}`
        #   — the `ruact_function_name` override map (action name → js identifier)
        #   for that controller. Defaults to real constant resolution.
        # @return [Array<Hash>] entries (string keys) sorted by `js_identifier`;
        #   shape: `js_identifier`, `kind` (always `"action"`), `http_method`,
        #   `path`, `segments` (Array<String>), `controller`, `action`.
        def collect(route_set, host_predicate: nil, overrides_for: nil)
          host_predicate ||= method(:default_host?)
          overrides_for  ||= method(:default_overrides_for)

          by_key = {}
          route_set.routes.each do |route|
            verb = route.verb.to_s
            next unless MUTATION_VERBS.include?(verb)

            controller = route.defaults[:controller]
            action = route.defaults[:action]
            next if controller.nil? || action.nil?
            next unless host_predicate.call(controller)

            key = [controller, action]
            existing = by_key[key]
            # PATCH/PUT collapse: keep the higher-priority verb only.
            next if existing && verb_rank(verb) >= verb_rank(existing["http_method"])

            by_key[key] = build_entry(route, verb, controller, action, overrides_for)
          end

          entries = by_key.values.sort_by { |entry| entry["js_identifier"] }
          detect_collisions!(entries)
          entries
        end

        private

        # Story 9.3 AC4 — two distinct routes that map to the same JS identifier
        # (after rename overrides) would emit two `export const` lines the same
        # name; fail loudly at boot naming BOTH origins so the dev knows exactly
        # which routes to disambiguate (via `ruact_function_name`). Mirrors the
        # cross-registry collision raise in {Ruact::ServerFunctions::Snapshot}.
        def detect_collisions!(entries)
          entries.group_by { |entry| entry["js_identifier"] }.each do |js_id, group|
            next if group.size < 2

            origins = group.map { |entry| "#{entry['controller']}##{entry['action']}" }
            raise Ruact::ConfigurationError,
                  "server-function naming collision: #{origins.join(' and ')} " \
                  "both map to JS identifier \"#{js_id}\" — disambiguate with " \
                  "`ruact_function_name :<action>, as: \"<other-name>\"`"
          end
        end

        def build_entry(route, verb, controller, action, overrides_for)
          override = overrides_for.call(controller)[action.to_s]
          {
            "js_identifier" => override || derive_identifier(controller, action, route),
            "kind" => "action",
            "http_method" => verb,
            "path" => clean_path(route),
            "segments" => route.required_parts.map(&:to_s),
            "controller" => controller,
            "action" => action
          }
        end

        # `lowerCamel(action) + Namespace*(Pascal) + Resource(Pascal)`.
        def derive_identifier(controller, action, route)
          segments = controller.split("/")
          resource_base = segments.last
          namespace = segments[0..-2]

          member = route.required_parts.include?(:id)
          singular = RESTFUL_WRITES.include?(action) || member
          resource_word = singular ? resource_base.singularize : resource_base

          lower_camel(action) +
            namespace.map { |part| pascal(part) }.join +
            pascal(resource_word)
        end

        # snake_case → lowerCamel, leading underscore preserved (mirrors
        # {NameBridge}'s rule for the action portion). Not run through NameBridge
        # directly: NameBridge validates the WHOLE symbol against reserved words,
        # but here the action is only a fragment of the final identifier.
        def lower_camel(str)
          str = str.to_s
          leading = str.start_with?("_") ? "_" : ""
          body = str.sub(/\A_+/, "")
          leading + body.gsub(/_+([a-z0-9])/) { Regexp.last_match(1).upcase }
        end

        # snake_case → PascalCase.
        def pascal(str)
          camel = lower_camel(str).sub(/\A_+/, "")
          camel.empty? ? camel : camel[0].upcase + camel[1..]
        end

        # `/posts/:id(.:format)` → `/posts/:id`. Drops the trailing format
        # optional; defensively strips any remaining optional `( … )` group.
        def clean_path(route)
          spec = route.path.spec.to_s
          spec = spec.delete_suffix("(.:format)")
          spec.gsub(/\([^)]*\)/, "")
        end

        def verb_rank(verb)
          VERB_PRIORITY.fetch(verb, 99)
        end

        # Real resolvers — used in the railtie/rake paths.
        def default_host?(controller)
          klass = host_class(controller)
          !klass.nil? && klass.include?(Ruact::Server)
        end

        def default_overrides_for(controller)
          klass = host_class(controller)
          return {} unless klass.respond_to?(:__ruact_function_name_overrides)

          klass.__ruact_function_name_overrides
        end

        def host_class(controller)
          "#{controller}_controller".camelize.safe_constantize
        rescue StandardError
          nil
        end
      end
    end
  end
end
