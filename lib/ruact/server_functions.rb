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
module Ruact
  module ServerFunctions
    autoload :NameBridge,         "ruact/server_functions/name_bridge"
    autoload :RegistryEntry,      "ruact/server_functions/registry_entry"
    autoload :Registry,           "ruact/server_functions/registry"
    autoload :Snapshot,           "ruact/server_functions/snapshot"
    autoload :SnapshotWriter,     "ruact/server_functions/snapshot_writer"
    autoload :Codegen,            "ruact/server_functions/codegen"
    autoload :ErrorRendering,     "ruact/server_functions/error_rendering"
    autoload :EndpointController, "ruact/server_functions/endpoint_controller"
    autoload :StandaloneContext, "ruact/server_functions/standalone_context"
    autoload :StandaloneDispatcher, "ruact/server_functions/standalone_dispatcher"
  end
end
