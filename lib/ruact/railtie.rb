# frozen_string_literal: true

require "rails"

module Ruact
  class Railtie < Rails::Railtie
    initializer "ruact.load_controller" do
      require_relative "controller"
    end

    rake_tasks do
      load File.expand_path("../tasks/rsc.rake", __dir__)
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
    # - ViewHelper provides __rsc_component__ in every view context
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
