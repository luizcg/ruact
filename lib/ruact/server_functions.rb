# frozen_string_literal: true

# Namespace for the server-functions subsystem (Story 8.0a — codegen surface
# that emits app/javascript/.ruact/server-functions.ts from the Rails route
# table). Story 9.9 demolished the v1 registry path; the route table is now the
# sole source of truth.
#
# - {Ruact::ServerFunctions::NameBridge} — Ruby symbol → JS identifier translation
#   (single source of truth; the Vite plugin reads the already-translated identifier
#   from the JSON snapshot and emits it as-is).
# - {Ruact::ServerFunctions::RouteSource} — collects mutation (non-GET) actions
#   from the drawn route table.
# - {Ruact::ServerFunctions::QuerySource} — collects read queries from the
#   `ruact_queries`-drawn GET routes.
# - {Ruact::ServerFunctions::Snapshot} — pure function: route entries → JSON-shaped Hash.
# - {Ruact::ServerFunctions::SnapshotWriter} — atomic, write-if-changed file I/O.
# - {Ruact::ServerFunctions::Codegen} — snapshot Hash → TypeScript module string.
require "json"

module Ruact
  module ServerFunctions
    autoload :NameBridge,         "ruact/server_functions/name_bridge"
    autoload :Snapshot,           "ruact/server_functions/snapshot"
    autoload :SnapshotWriter,     "ruact/server_functions/snapshot_writer"
    autoload :Codegen,            "ruact/server_functions/codegen"
    autoload :RouteSource,        "ruact/server_functions/route_source"
    autoload :QuerySource,        "ruact/server_functions/query_source"
    autoload :ErrorRendering,     "ruact/server_functions/error_rendering"
    autoload :ValidationErrors,   "ruact/server_functions/validation_errors"
    autoload :QueryContext, "ruact/server_functions/query_context"
    autoload :QueryDispatch, "ruact/server_functions/query_dispatch"

    # Story 9.3 / 9.9 — orchestrates the route-driven (v2) codegen. Reads the
    # route table via {RouteSource} + {QuerySource}, writes the version-2 bridge
    # to the REAL path (write-if-changed), and renders the TS via the Ruby
    # {Codegen}. As of Story 9.9 this is the SOLE writer of the real bridge —
    # the v1 registry path and the parallel `.next` target were demolished
    # (epic decision #6: route-driven codegen owns `server-functions.ts`
    # unconditionally; the module path `@/.ruact/server-functions` never changed,
    # so React imports are unchanged by construction).
    #
    # AC2 — transparency over silence: the exposed names are ALWAYS logged so a
    # routed non-GET action never becomes a callable server function silently.
    #
    # Story 9.5 — the `entries` array carries BOTH mutation actions (from
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

      json_path = root.join("tmp/cache/ruact/server-functions.json")
      ts_path   = root.join("app/javascript/.ruact/server-functions.ts")

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
