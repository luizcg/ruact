# frozen_string_literal: true

require "rails"

module Ruact
  class Railtie < Rails::Railtie
    initializer "ruact.load_controller" do
      require_relative "controller"
      # Story 9.1 — the v2 route-driven marker concern (`include Ruact::Server`).
      require_relative "server"
      # Story 9.4 (D8) — requiring ruact/routing installs the `ruact_queries`
      # macro into ActionDispatch::Routing::Mapper (a Mapper extension, NOT a
      # mounted route — the host's routes.rb explicitly mounts each query
      # class). Initializers all run before the routes file is loaded, so the
      # macro is in place for the first draw.
      require_relative "routing"
    end

    rake_tasks { load File.expand_path("../tasks/ruact.rake", __dir__) }

    # Load the client manifest at boot (and on each code reload in development).
    # config.to_prepare runs once in production and before every code reload in
    # development, ensuring the manifest is always current without file I/O per
    # request.
    #
    # Missing manifest behaviour (AC#5, #6):
    # - development: logs a [ruact] warning; app starts normally
    # - production:  raises ManifestError; app does not start
    #
    # Also registers ActionView integration:
    # - ViewHelper provides __ruact_component__ in every view context
    # - ErbPreprocessorHook applies the RSC preprocessor to all ERB templates
    #   (layouts, views, partials) transparently via prepend.
    config.to_prepare do
      manifest_path = Ruact.config.manifest_path ||
                      Rails.root.join("public", "react-client-manifest.json")
      manifest_path = Pathname.new(manifest_path) unless manifest_path.respond_to?(:exist?)

      if manifest_path.exist?
        Ruact.manifest = Ruact::ClientManifest.load(manifest_path)
      else
        Ruact::Railtie.check_manifest!(manifest_path)
      end

      require_relative "view_helper"
      require_relative "erb_preprocessor_hook"
      ActionView::Base.include(Ruact::ViewHelper)
      ActionView::Template::Handlers::ERB.prepend(Ruact::ErbPreprocessorHook)

      # Story 9.9 — the route-driven (v2) codegen is the SOLE writer of the
      # real Rails↔Vite bridge (`tmp/cache/ruact/server-functions.json`, which
      # the Vite plugin renders into `app/javascript/.ruact/server-functions.ts`).
      # The v1 registry path was demolished in this story (epic decision #6:
      # the parallel `.next` target ceases to exist; route-driven codegen owns
      # the real file unconditionally — there are no v1 declarations possible
      # anymore).
      Ruact::Railtie.write_server_functions_snapshot!
    end

    # Detect streaming capability at boot and log the active mode (AC#1–3).
    # Also warns in development if the Vite dev server is not running (AC#4, #7).
    config.after_initialize do
      # Story 9.9 — guaranteed-correct first-boot codegen. By `after_initialize`
      # the route table is fully drawn on EVERY Rails version, so this write
      # always sees the complete route set (the `to_prepare` write above can run
      # mid-finalization on Rails < 8, before routes exist — that write is the
      # dev-reload refresh path; this one is the authoritative boot write).
      # Write-if-changed makes the pair idempotent — at most one real write.
      Ruact::Railtie.write_server_functions_snapshot!

      Ruact::Railtie.detect_streaming_mode!
      next unless Rails.env.development?

      Ruact::Railtie.check_vite!
    end

    # Detects the web server at boot, stores the streaming mode, and logs the result (AC#1–3).
    # Detection is constant-based (zero I/O): Puma → enabled, Unicorn/Passenger → buffered,
    # unknown → buffered (safe mode).
    def self.detect_streaming_mode!
      mode, label = if defined?(::Puma::Server)
                      [:enabled,  "Puma detected"]
                    elsif defined?(::Falcon::Server)
                      [:enabled,  "Falcon detected"]
                    elsif defined?(::Unicorn)
                      [:buffered, "Unicorn detected"]
                    elsif defined?(::PhusionPassenger)
                      [:buffered, "Passenger detected"]
                    else
                      [:buffered, "server unknown — defaulting to safe mode"]
                    end

      Ruact.streaming_mode = mode
      verb = mode == :enabled ? "enabled" : "buffered"
      Rails.logger.info "[ruact] streaming: #{verb} (#{label})"
      mode
    end

    # Checks whether the Vite dev server is accessible and warns if not (AC#4).
    # Extracted as a class method for direct testability without a full Rails app.
    def self.check_vite!
      require "socket"
      require "uri"
      uri  = URI.parse(Ruact.config.vite_dev_server)
      host = uri.host || "localhost"
      port = uri.port || 5173
      # `connect_timeout` so a blackholed/remote configured host can't stall dev
      # boot from `after_initialize` until the OS TCP timeout (matches
      # ViewHelper#vite_dev_running?).
      TCPSocket.new(host, port, connect_timeout: 1).close
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
      # Broad rescue (incl. SocketError) because the host is now configurable: a
      # misconfigured/unresolvable `vite_dev_server` must downgrade to this dev
      # warning, never crash boot from `after_initialize`. `host`/`port` are
      # assigned before the connect attempt, so they are always in scope here.
      Rails.logger.warn "[ruact] Vite dev server not detected at #{host}:#{port} " \
                        "— run npm run dev for HMR"
    end

    # Story 9.9 — writes the route-driven (v2) server-functions JSON snapshot
    # to the REAL bridge (`tmp/cache/ruact/server-functions.json`) on every
    # `config.to_prepare`. The Vite plugin renders this JSON into
    # `app/javascript/.ruact/server-functions.ts`. The write is short-circuited
    # when the entries are unchanged (Story 8.0a pitfall #1 — dev mode fires
    # `to_prepare` per request; a naive rewrite would burn IOPS and churn the
    # Vite plugin's chokidar watcher).
    #
    # Cold-boot ordering (folded in from the Story 9.8 host workaround): on the
    # very first boot `to_prepare` can run BEFORE `routes.rb` is drawn, leaving
    # the route set empty so the codegen would emit zero functions. Force the
    # route table to load first via `routes_reloader.execute_unless_loaded` so
    # RouteSource/QuerySource see every route.
    #
    # The force-load is guarded: when `to_prepare` fires from INSIDE the
    # boot finisher (Rails draws routes during `initialize!`, and on Rails < 8
    # re-entering `execute_unless_loaded` there raises `FrozenError` against the
    # in-progress route set), we SKIP THE WRITE ENTIRELY rather than publish a
    # snapshot from a mid-draw/incomplete route set (which Vite could observe as
    # a transient empty/stale bridge — Codex R1). The authoritative boot write
    # is the `after_initialize` call, which always sees the fully-drawn table;
    # the dev-reload `to_prepare` then refreshes from a settled table.
    #
    # @return [Array<Hash>, nil] the exposed v2 entries, or nil if the write was
    #   skipped because routes were mid-draw.
    def self.write_server_functions_snapshot!
      return nil unless force_routes_loaded!

      Ruact::ServerFunctions.write_v2_snapshot!(
        route_set: Rails.application.routes, root: Rails.root
      )
    end

    # Idempotently force the route table to load. Returns true when the table is
    # safely loaded (so the caller may read it), false when the force re-entered
    # the boot finisher's in-progress draw (Rails < 8 raises `FrozenError`
    # there) — in which case the caller must NOT write, leaving the table to the
    # routes initializer + the later `after_initialize` write.
    #
    # @return [Boolean] true if routes are safe to read, false if mid-draw.
    def self.force_routes_loaded!
      reloader = Rails.application.routes_reloader
      return true unless reloader.respond_to?(:execute_unless_loaded)

      reloader.execute_unless_loaded
      true
    rescue FrozenError
      false
    end

    # Checks whether the manifest exists and either warns (dev) or raises (prod).
    # Extracted as a class method for direct testability without a full Rails app.
    def self.check_manifest!(manifest_path)
      if Rails.env.production?
        raise ManifestError,
              "react-client-manifest.json not found — run vite build before deploying"
      else
        Rails.logger.warn "[ruact] react-client-manifest.json not found at " \
                          "#{manifest_path} — RSC rendering will be unavailable. " \
                          "Run 'npm run build' or start the Vite dev server."
      end
    end
  end
end
