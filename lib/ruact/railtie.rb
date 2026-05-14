# frozen_string_literal: true

require "rails"

module Ruact
  class Railtie < Rails::Railtie
    initializer "ruact.load_controller" do
      require_relative "controller"
    end

    rake_tasks do
      load File.expand_path("../tasks/ruact.rake", __dir__)
    end

    # Story 8.1 — clear the action/query registries on every code reload so
    # removed `ruact_action` declarations don't linger in the registry. We hook
    # `before_class_unload` (BEFORE Zeitwerk tears down constants) rather than
    # `to_prepare` (AFTER reload): controller class bodies re-evaluate during
    # the reload itself, and clearing in `to_prepare` would wipe their fresh
    # registrations.
    #
    # First-boot is naturally safe — registries start empty, so there's nothing
    # to clear; the very first controller class-body evaluation populates them.
    # In production this hook never fires (no reloads), which is correct.
    initializer "ruact.attach_registry_clear_hook" do |app|
      app.reloader.before_class_unload do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!
      end
    end

    # Story 8.1 — mount the single gem-managed endpoint that dispatches all
    # `ruact_action` calls. The route is `POST /__ruact/fn/:name`; the
    # controller resolves `:name` against `Ruact.action_registry` (and, once
    # Story 9.1 lands, `Ruact.query_registry`) and delegates execution to the
    # entry's host controller class via Rails' normal `dispatch` flow.
    #
    # `routes.append` (not `routes.draw`) appends to the host's routes after
    # they're defined, so the gem's endpoint can never accidentally shadow a
    # host route — the host always wins on conflicts.
    initializer "ruact.mount_server_functions_route" do |app|
      app.routes.append do
        post "/__ruact/fn/:name",
             to: "ruact/server_functions/endpoint#dispatch_action",
             as: :ruact_server_function,
             constraints: { name: /[a-zA-Z_][a-zA-Z0-9_]*/ }
      end
    end

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

      # Story 8.1 review-batch 3 (2026-05-14) — force-load all controller
      # files BEFORE writing the snapshot so the registry sees every
      # `ruact_action` declaration. Without this, lazy autoload (Rails dev's
      # default for `eager_load = false`) means a controller that hasn't
      # been requested yet isn't loaded, so its `ruact_action` calls don't
      # populate the registry — the codegen would then emit a stale TS
      # module missing those exports until the controller is hit at least
      # once. The endpoint controller would also 404 those names.
      Ruact::Railtie.force_load_controllers!

      Ruact::Railtie.write_server_functions_snapshot!
    end

    # Detect streaming capability at boot and log the active mode (AC#1–3).
    # Also warns in development if the Vite dev server is not running (AC#4, #7).
    config.after_initialize do
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
      TCPSocket.new("localhost", 5173).close
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      Rails.logger.warn "[ruact] Vite dev server not detected at localhost:5173 " \
                        "— run npm run dev for HMR"
    end

    # Story 8.1 review-batch 3 (2026-05-14) — force-loads every controller
    # file under `Rails.application.config.paths["app/controllers"]` so the
    # `ruact_action` registrations populate the registry on a clean boot.
    #
    # Without this, Rails' dev-mode lazy autoload only loads a controller
    # when it's first referenced (typically the first request that routes
    # to it). That means the codegen snapshot in `to_prepare` would miss
    # any controller not yet touched.
    #
    # Implementation: glob the `app/controllers` directories listed in the
    # Rails paths configuration and `require_dependency` each
    # `*_controller.rb` file. `require_dependency` works in both Zeitwerk
    # (Rails 7+) and the classic autoloader. On Zeitwerk it is implemented
    # as `Rails.autoloaders.main.load_file(path)` under the hood.
    #
    # Errors are surfaced as `Ruact::Error` with a controller hint so the
    # developer sees a meaningful boot failure instead of a silent skip.
    #
    # @return [Integer] number of controller files loaded.
    def self.force_load_controllers!
      paths = Rails.application.config.paths["app/controllers"]
      return 0 unless paths.respond_to?(:existent)

      loaded = 0
      paths.existent.each do |dir|
        Dir.glob("#{dir}/**/*_controller.rb").each do |file|
          # `require_dependency` is the cross-autoloader-compatible API; it
          # tells the autoloader to load the file AND track it for reload.
          # In Rails 7+/Zeitwerk this delegates to Zeitwerk's autoloader.
          require_dependency(file)
          loaded += 1
        end
      end
      loaded
    rescue LoadError, NameError => e
      raise Ruact::Error,
            "ruact: failed to force-load a controller while populating " \
            "Ruact.action_registry: #{e.class}: #{e.message}. The gem " \
            "force-loads `app/controllers/**/*_controller.rb` at " \
            "`config.to_prepare` so registries are complete on first boot."
    end

    # Writes the server-functions JSON snapshot to tmp/cache/ruact/ on every
    # config.to_prepare. The write is short-circuited when the registry payload
    # is unchanged (Story 8.0a — pitfall #1: dev mode fires to_prepare per
    # request; a naive rewrite would burn IOPS and confuse the Vite plugin's
    # chokidar watcher).
    #
    # @return [Boolean] true if a fresh file was written, false if unchanged.
    def self.write_server_functions_snapshot!
      path = Rails.root.join("tmp/cache/ruact/server-functions.json")
      Ruact::ServerFunctions::Snapshot.generate!(
        action_registry: Ruact.action_registry,
        query_registry: Ruact.query_registry,
        path: path
      )
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
