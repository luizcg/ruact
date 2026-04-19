# frozen_string_literal: true

require "socket"
require "pathname"

module Ruact
  # Runs a suite of installation health checks and prints ✓/✗ per check.
  # Extracted from the rsc:doctor Rake task for direct testability (FR27).
  class Doctor
    CHECKS = %i[manifest vite controller layout streaming].freeze

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
