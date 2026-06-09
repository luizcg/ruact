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
    autoload :ErrorRendering,     "ruact/server_functions/error_rendering"
    autoload :EndpointController, "ruact/server_functions/endpoint_controller"
    autoload :StandaloneContext, "ruact/server_functions/standalone_context"
    autoload :StandaloneDispatcher, "ruact/server_functions/standalone_dispatcher"

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
    # @param route_set [#routes] the Rails route set.
    # @param root [Pathname] the app root (for `tmp/cache` + `app/javascript`).
    # @param logger [#info, nil] logger for the exposure line; defaults to
    #   `Rails.logger` when Rails is loaded, else nil.
    # @return [Array<Hash>] the exposed v2 entries.
    def self.write_v2_snapshot!(route_set:, root:, logger: default_logger)
      entries = RouteSource.collect(route_set)

      json_path = root.join("tmp/cache/ruact/server-functions.next.json")
      ts_path   = root.join("app/javascript/.ruact/server-functions.next.ts")

      # Read back from the on-disk bridge (not a fresh dump) so a stable route
      # table never churns the timestamp baked into the rendered TS header.
      Snapshot.generate_v2!(entries: entries, path: json_path)
      Codegen.generate_ts!(snapshot: JSON.parse(File.read(json_path)), output_path: ts_path)

      unless entries.empty?
        logger&.info "[ruact] codegen: exposing #{entries.map { |e| e['js_identifier'] }.join(', ')}"
      end
      entries
    end

    def self.default_logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end
  end
end
