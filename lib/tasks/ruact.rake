# frozen_string_literal: true

namespace :ruact do
  desc "Check ruact installation and configuration (FR27)"
  task doctor: :environment do
    require "ruact/doctor"
    exit 1 unless Ruact::Doctor.run
  end

  namespace :server_functions do
    # Story 8.0a / 9.9 — manual / CI / production codegen entry point. Mirrors
    # the Railtie hook (config.to_prepare) for environments where the dev server
    # is not running (CI, deploy pipelines, container build steps).
    #
    # Story 9.9 — the route-driven (v2) codegen is the sole writer. The task
    # forces the route table to load, then writes the v2 snapshot to the REAL
    # bridge (`tmp/cache/ruact/server-functions.json`) and renders the TS module
    # (`app/javascript/.ruact/server-functions.ts`), both write-if-changed.
    #
    # Exit codes: 0 on success or no-op rewrites; 1 on
    # `Ruact::ConfigurationError` (a server-function naming collision, an
    # invalid name, or a corrupted snapshot rejected by the codegen guards).
    desc "Regenerate app/javascript/.ruact/server-functions.ts from the Rails route table (Story 9.9)"
    task generate: :environment do
      require "ruact/server_functions"

      begin
        Rails.application.routes_reloader.execute_unless_loaded
        Ruact::ServerFunctions.write_v2_snapshot!(
          route_set: Rails.application.routes, root: Rails.root, logger: Rails.logger
        )
      rescue Ruact::ConfigurationError, Errno::ENOENT, JSON::ParserError => e
        warn "[ruact] error: #{e.message}"
        exit 1
      end
    end
  end
end
