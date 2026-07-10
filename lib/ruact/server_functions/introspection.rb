# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 15.3 (FR107) — the machine-readable `ruact:routes --json` document:
    # a read-only, side-effect-free view of the accessor/route table for headless
    # agents and CI gates. Reuses the SAME collectors codegen consumes (via
    # {Ruact::ServerFunctions.introspect}), so the introspection can never fork a
    # parallel derivation and never writes the codegen bridge / TS module.
    #
    # ## Shape
    #
    #     { "schema_version" => Integer,
    #       "accessors" => [
    #         { "accessor" => String,   # the JS identifier (js_identifier)
    #           "kind"     => String,   # "action" | "query"
    #           "verb"     => String,   # HTTP method
    #           "path"     => String,   # cleaned route path
    #           "segments" => Array<String>,
    #           "params"   => [{ "name" => String, "required" => Boolean }] } ] }
    #
    # Queries carry their declared kwargs as `params` (Story 13.4); actions carry
    # their required path segments, uniformly shaped as `{ name, required: true }`.
    # Per Story 15.3 decision D3 there is NO per-accessor component-contract link
    # (accessors are server functions, not components) — the table reports
    # accessors faithfully and omits the "target component contract" clause.
    module Introspection
      # Version of the `ruact:routes --json` document. **EXPERIMENTAL / UNSTABLE**:
      # `0` signals the shape may change without a major version bump while the
      # agent-facing surface is iterated — gate any parser on it. Distinct from
      # {Ruact::Doctor::SCHEMA_VERSION} (a separate, independently-versioned
      # document) and from {Snapshot::VERSION_V2} (the internal codegen bridge).
      SCHEMA_VERSION = 0

      class << self
        # Builds the `ruact:routes --json` document from +route_set+. The resolver
        # callables default to real constant resolution; specs inject lambdas.
        #
        # @param route_set [#routes] the Rails route set.
        # @param host_predicate [#call, nil] forwarded to {ServerFunctions.introspect}.
        # @param overrides_for [#call, nil] forwarded to {ServerFunctions.introspect}.
        # @param query_class_for [#call, nil] forwarded to {ServerFunctions.introspect}.
        # @return [Hash] the schema-versioned introspection document.
        # @raise [Ruact::ConfigurationError] on any naming collision.
        def as_json(route_set:, host_predicate: nil, overrides_for: nil, query_class_for: nil)
          entries = ServerFunctions.introspect(
            route_set: route_set,
            host_predicate: host_predicate,
            overrides_for: overrides_for,
            query_class_for: query_class_for
          )
          {
            "schema_version" => SCHEMA_VERSION,
            "accessors" => entries.map { |entry| shape(entry) }
          }
        end

        private

        def shape(entry)
          {
            "accessor" => entry["js_identifier"],
            "kind" => entry["kind"],
            "verb" => entry["http_method"],
            "path" => entry["path"],
            "segments" => entry["segments"],
            "params" => params_for(entry)
          }
        end

        # Queries declare their params as kwargs (Story 13.4 → `params`); actions
        # derive them from required path segments. Uniform `{ name, required }`.
        def params_for(entry)
          return entry["params"] if entry["kind"] == "query"

          entry["segments"].map { |segment| { "name" => segment, "required" => true } }
        end
      end
    end
  end
end
