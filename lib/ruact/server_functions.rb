# frozen_string_literal: true

# Namespace for the server-functions subsystem (Story 8.0a — codegen surface that
# emits app/javascript/.ruact/server-functions.ts from the gem-side registries).
#
# - {Ruact::ServerFunctions::NameBridge} — Ruby symbol → JS identifier translation
#   (single source of truth; the Vite plugin reads the already-translated identifier
#   from the JSON snapshot and emits it as-is).
# - {Ruact::ServerFunctions::RegistryEntry} — immutable record for a single
#   registered server function.
# - {Ruact::ServerFunctions::Registry} — storage + register/clear + collision
#   detection. Populated by Story 8.1 (`ruact_action`) and Story 9.1 (`ruact_query`).
# - {Ruact::ServerFunctions::Snapshot} — pure function: registries → JSON-shaped Hash.
# - {Ruact::ServerFunctions::SnapshotWriter} — atomic, write-if-changed file I/O.
# - {Ruact::ServerFunctions::Codegen} — snapshot Hash → TypeScript module string.
#
# Empty registries are valid (Story 8.0a ships them empty; 8.1 and 9.1 populate).
require "json"

module Ruact
  module ServerFunctions
    autoload :NameBridge,         "ruact/server_functions/name_bridge"
    autoload :RegistryEntry,      "ruact/server_functions/registry_entry"
    autoload :Registry,           "ruact/server_functions/registry"
    autoload :Snapshot,           "ruact/server_functions/snapshot"
    autoload :SnapshotWriter,     "ruact/server_functions/snapshot_writer"
    autoload :Codegen,            "ruact/server_functions/codegen"
    autoload :RouteSource,        "ruact/server_functions/route_source"
    autoload :QuerySource,        "ruact/server_functions/query_source"
    autoload :ErrorRendering,     "ruact/server_functions/error_rendering"
    autoload :EndpointController, "ruact/server_functions/endpoint_controller"
    autoload :StandaloneContext, "ruact/server_functions/standalone_context"
    autoload :StandaloneDispatcher, "ruact/server_functions/standalone_dispatcher"
    autoload :QueryContext, "ruact/server_functions/query_context"
    autoload :QueryDispatch, "ruact/server_functions/query_dispatch"

    # Story 9.3 — orchestrates the route-driven (v2) codegen target. Reads the
    # route table via {RouteSource}, writes the version-2 bridge to the PARALLEL
    # `.next` path (write-if-changed), and renders the inspection TS via the
    # Ruby {Codegen} (Vite does not watch `.next`). Per AC5 the `.next` target is
    # for parity tests + inspection only — never imported by application code —
    # so the real `server-functions.ts` (v1, rendered by Vite) is untouched
    # (AC6). The Decision-#6 ownership flip (zero v1 declarations → v2 owns the
    # real file) is Story 9.8's job.
    #
    # AC2 — transparency over silence: the exposed names are ALWAYS logged so a
    # routed non-GET action never becomes a callable server function silently.
    #
    # Story 9.5 — the `entries` array now carries BOTH mutation actions (from
    # {RouteSource}) and read queries (from {QuerySource}); they share ONE
    # merged JS namespace. {.detect_merged_namespace_collisions!} catches a
    # route×query clash (each source already catches its own intra-kind
    # collisions); the rename-override macro `ruact_function_name` on the
    # mutation side (or renaming the query method) resolves it.
    #
    # @param route_set [#routes] the Rails route set.
    # @param root [Pathname] the app root (for `tmp/cache` + `app/javascript`).
    # @param logger [#info, nil] logger for the exposure line; defaults to
    #   `Rails.logger` when Rails is loaded, else nil.
    # @return [Array<Hash>] the exposed v2 entries (actions + queries).
    def self.write_v2_snapshot!(route_set:, root:, logger: default_logger)
      actions = RouteSource.collect(route_set)
      queries = QuerySource.collect(route_set)
      entries = (actions + queries).sort_by { |entry| entry["js_identifier"] }
      detect_merged_namespace_collisions!(entries)

      json_path = root.join("tmp/cache/ruact/server-functions.next.json")
      ts_path   = root.join("app/javascript/.ruact/server-functions.next.ts")

      # Read back from the on-disk bridge (not a fresh dump) so a stable route
      # table never churns the timestamp baked into the rendered TS header.
      Snapshot.generate_v2!(entries: entries, path: json_path)
      Codegen.generate_ts!(snapshot: JSON.parse(File.read(json_path)), output_path: ts_path)

      # AC2 — ALWAYS log what is exposed (even "(none)"), so a routed non-GET
      # action never becomes a callable server function silently.
      names = entries.empty? ? "(none)" : entries.map { |e| e["js_identifier"] }.join(", ")
      logger&.info "[ruact] codegen: exposing #{names}"
      entries
    end

    def self.default_logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end

    # Story 9.5 (Task 2) — the merged JS namespace covers route (action)
    # entries AND query entries. {RouteSource} already rejects action×action
    # collisions and {QuerySource} rejects query×query; this final pass catches
    # a route×query clash — two distinct origins (one a mutation route, one a
    # query method) mapping to the same `js_identifier` would emit two
    # `export const <id>` lines and crash the generated module at load. Fail
    # loudly at boot naming BOTH origins. The escape hatch is the
    # `ruact_function_name :<action>, as: "<id>"` rename macro on the mutation
    # controller (Story 9.3) or renaming the colliding query method.
    #
    # @param entries [Array<Hash>] merged action + query entries.
    # @raise [Ruact::ConfigurationError]
    def self.detect_merged_namespace_collisions!(entries)
      entries.group_by { |entry| entry["js_identifier"] }.each do |js_id, group|
        next if group.size < 2

        origins = group.map { |entry| "#{entry['controller']}##{entry['action']}" }
        raise Ruact::ConfigurationError,
              "server-function naming collision: #{origins.join(' and ')} " \
              "both map to JS identifier \"#{js_id}\" — disambiguate with " \
              "`ruact_function_name :<action>, as: \"<other-name>\"` on the mutation " \
              "controller, or rename the query method."
      end
    end
  end
end
