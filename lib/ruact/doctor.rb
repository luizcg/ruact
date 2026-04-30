# frozen_string_literal: true

require "socket"
require "pathname"

module Ruact
  # Runs a suite of installation health checks and prints ✓/✗ per check.
  # Extracted from the rsc:doctor Rake task for direct testability (FR27).
  class Doctor
    CHECKS = %i[manifest vite controller layout streaming legacy_constant].freeze
    LEGACY_CONSTANT_RE = /(?<![A-Za-z_])(RailsRsc|rails_rsc)(?![A-Za-z_])/
    LEGACY_SCAN_GLOBS = ["config/initializers/**/*.rb", "app/**/*.rb"].freeze

    # Runs all checks, prints results, returns true if all pass.
    def self.run
      new.run
    end

    def run
      results = CHECKS.map { |check| send(:"check_#{check}") }
      results.each { |status, message| puts format_result(status, message) }
      passed = results.all? { |status, _| status == :pass }
      puts "Run rails generate ruact:install to fix configuration issues" unless passed
      passed
    end

    private

    def check_manifest
      path = manifest_path
      if Pathname(path).exist?
        [:pass, "Manifest found at #{path}"]
      else
        [:fail, "Manifest not found — run vite build"]
      end
    end

    def check_vite
      TCPSocket.new("localhost", 5173).close
      [:pass, "Vite accessible at localhost:5173"]
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      [:fail, "Vite not accessible at localhost:5173 — run npm run dev"]
    end

    def check_controller
      path = Rails.root.join("app", "controllers", "application_controller.rb")
      if File.exist?(path) && File.read(path).include?("Ruact::Controller")
        [:pass, "Ruact::Controller included in ApplicationController"]
      else
        [:fail, "Ruact::Controller not included in ApplicationController"]
      end
    end

    def check_layout
      path = Rails.root.join("app", "views", "layouts", "application.html.erb")
      if File.exist?(path) && File.read(path).include?("ruact: root")
        [:pass, "React shell present in application.html.erb"]
      else
        [:fail, "React shell missing from application.html.erb"]
      end
    end

    def check_streaming
      mode  = Ruact.streaming_mode || :buffered
      label = mode == :enabled ? "enabled" : "buffered"
      [:pass, "streaming: #{label} (#{streaming_server_hint})"]
    end

    # Detects host-app references to the legacy `RailsRsc` constant or
    # `rails_rsc` require path left over from the rename to `ruact`.
    def check_legacy_constant
      offenses = LEGACY_SCAN_GLOBS.flat_map do |glob|
        Dir[Rails.root.join(glob)].flat_map do |file|
          File.foreach(file).with_index(1).filter_map do |line, lineno|
            next unless LEGACY_CONSTANT_RE.match?(line)

            "#{file}:#{lineno}"
          end
        end
      end
      return [:pass, "No legacy `RailsRsc` / `rails_rsc` references found"] if offenses.empty?

      [:fail,
       "Legacy `RailsRsc` / `rails_rsc` references found in #{offenses.length} location(s) " \
       "(first: #{offenses.first}). Replace `RailsRsc` with `Ruact` and " \
       "`require \"rails_rsc\"` with `require \"ruact\"` (gem renamed in v0.0.x)"]
    end

    def streaming_server_hint
      return "Puma"      if defined?(::Puma)
      return "Unicorn"   if defined?(::Unicorn)
      return "Passenger" if defined?(::PhusionPassenger)

      "unknown"
    end

    def manifest_path
      Ruact.config.manifest_path ||
        Rails.root.join("public", "react-client-manifest.json")
    end

    def format_result(status, message)
      status == :pass ? "✓ #{message}" : "✗ #{message}"
    end
  end
end
