# frozen_string_literal: true

namespace :ruact do
  desc "Check ruact installation and configuration (FR27)"
  task doctor: :environment do
    require "ruact/doctor"
    exit 1 unless Ruact::Doctor.run
  end

  namespace :server_functions do
    # Story 8.0a — manual / CI / production codegen entry point. Mirrors the
    # Railtie hook (config.to_prepare) for environments where the dev server
    # is not running (CI, deploy pipelines, container build steps).
    #
    # Exits non-zero with a clear `[ruact] error:` line on:
    #   - invalid symbol shape (naming-bridge rule violation)
    #   - JS-identifier collision between two registered Ruby symbols
    # Idempotent: a second run on an unchanged registry produces no file writes
    # and exits 0 (the write-if-changed guard inside Snapshot.generate! /
    # Codegen.generate_ts! handles this).
    desc "Regenerate app/javascript/.ruact/server-functions.ts from the gem registries (Story 8.0a)"
    task generate: :environment do
      require "ruact/server_functions"

      json_path = Rails.root.join("tmp/cache/ruact/server-functions.json")
      ts_path   = Rails.root.join("app/javascript/.ruact/server-functions.ts")

      begin
        Ruact::ServerFunctions::Snapshot.generate!(
          action_registry: Ruact.action_registry,
          query_registry: Ruact.query_registry,
          path: json_path
        )
        snapshot = Ruact::ServerFunctions::Snapshot.dump(
          Ruact.action_registry, Ruact.query_registry
        )
        Ruact::ServerFunctions::Codegen.generate_ts!(
          snapshot: snapshot,
          output_path: ts_path
        )
      rescue Ruact::ConfigurationError => e
        warn "[ruact] error: #{e.message}"
        exit 1
      end
    end
  end
end
