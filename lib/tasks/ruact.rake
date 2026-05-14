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
    # Pipeline:
    #   1. `Snapshot.generate!` writes the JSON bridge IF its registry
    #      payload differs from the on-disk version (write-if-changed by
    #      payload, not by timestamp).
    #   2. `Snapshot.read_for_codegen` re-loads the persisted JSON — this is
    #      the on-disk source of truth that the Vite plugin consumes, and
    #      reusing it (instead of freshly dumping with a new timestamp)
    #      keeps the TS module byte-stable on unchanged registries.
    #   3. `Codegen.generate_ts!` writes the TS module via the same write-
    #      if-changed guard.
    #
    # Exit codes: 0 on success or no-op rewrites; 1 on
    # `Ruact::ConfigurationError` (invalid symbol shape per AC7, cross-
    # registry collision, invalid kind, or a corrupted snapshot rejected by
    # the codegen's identifier guard).
    desc "Regenerate app/javascript/.ruact/server-functions.ts from the gem registries (Story 8.0a)"
    task generate: :environment do
      require "ruact/server_functions"
      require "json"

      json_path = Rails.root.join("tmp/cache/ruact/server-functions.json")
      ts_path   = Rails.root.join("app/javascript/.ruact/server-functions.ts")

      begin
        Ruact::ServerFunctions::Snapshot.generate!(
          action_registry: Ruact.action_registry,
          query_registry: Ruact.query_registry,
          path: json_path
        )
        # Pass-2 patch 2026-05-14 — the JSON can disappear OR be partially
        # written between `generate!` and `File.read` (a concurrent rake
        # invocation flushing mid-write, a tmpdir wipe by Spring, an
        # externally-managed `tmp/cache` cleaner). Both `Errno::ENOENT` AND
        # `JSON::ParserError` indicate the same TOCTOU window — re-invoke
        # `generate!` once with the same registries; if the second read
        # still fails we surface the error with a clear "[ruact] error"
        # envelope so the caller sees a real failure rather than an
        # unwrapped Errno / parser backtrace.
        snapshot = begin
          JSON.parse(File.read(json_path)).transform_keys(&:to_sym)
        rescue Errno::ENOENT, JSON::ParserError
          Ruact::ServerFunctions::Snapshot.generate!(
            action_registry: Ruact.action_registry,
            query_registry: Ruact.query_registry,
            path: json_path
          )
          JSON.parse(File.read(json_path)).transform_keys(&:to_sym)
        end
        Ruact::ServerFunctions::Codegen.generate_ts!(
          snapshot: snapshot,
          output_path: ts_path
        )
      rescue Ruact::ConfigurationError, Errno::ENOENT, JSON::ParserError => e
        warn "[ruact] error: #{e.message}"
        exit 1
      end
    end
  end
end
