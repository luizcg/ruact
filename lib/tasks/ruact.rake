# frozen_string_literal: true

namespace :ruact do
  # Story 15.3 (FR107) — `--json` is passed after a `--` separator so neither
  # Rails nor Rake tries to parse it as an option: `bin/rails ruact:doctor -- --json`.
  # Everything after `--` lands in ARGV, which the task scans. A captured local
  # (not a constant) so re-loading this rakefile — e.g. specs that load it into
  # an isolated Rake::Application — does not warn about constant redefinition.
  json_mode = -> { ARGV.include?("--json") }

  desc "Check ruact installation and configuration (FR27). Append `-- --json` " \
       "for a machine-readable report (EXPERIMENTAL shape — gate on schema_version)."
  task doctor: :environment do
    require "ruact/doctor"

    if json_mode.call
      require "json"
      report = Ruact::Doctor.new.as_json
      puts JSON.pretty_generate(report)
      exit 1 unless report["status"] == "pass"
    else
      exit 1 unless Ruact::Doctor.run
    end
  end

  # Story 15.3 (FR107) — read-only introspection of the accessor/route table
  # (the SAME single source of truth codegen consumes) for headless agents & CI.
  # Side-effect-free: it does NOT write the codegen bridge or the TS module.
  # `-- --json` emits the machine-readable document; the bare task prints a
  # compact human table. Exits 1 (message on stderr) on a naming collision,
  # mirroring `ruact:server_functions:generate`.
  desc "Print the ruact accessor/route table. Append `-- --json` for a " \
       "machine-readable document (EXPERIMENTAL shape — gate on schema_version)."
  task routes: :environment do
    require "ruact/server_functions"

    begin
      Rails.application.routes_reloader.execute_unless_loaded

      if json_mode.call
        require "json"
        puts JSON.pretty_generate(
          Ruact::ServerFunctions::Introspection.as_json(route_set: Rails.application.routes)
        )
      else
        entries = Ruact::ServerFunctions.introspect(route_set: Rails.application.routes)
        if entries.empty?
          puts "[ruact] no server-function accessors (no Ruact::Server actions or mounted queries)"
        else
          puts "[ruact] server-function accessors:"
          entries.each do |entry|
            puts format("  %-6<verb>s %-28<accessor>s %<path>s",
                        verb: entry["http_method"], accessor: entry["js_identifier"], path: entry["path"])
          end
        end
      end
    rescue Ruact::ConfigurationError, Errno::ENOENT, JSON::ParserError => e
      warn "[ruact] error: #{e.message}"
      exit 1
    end
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
