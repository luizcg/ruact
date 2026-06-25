# frozen_string_literal: true

require "socket"
require "pathname"

module Ruact
  # Runs a suite of installation health checks and prints ✓/✗ per check.
  # Extracted from the ruact:doctor Rake task for direct testability (FR27).
  class Doctor
    CHECKS = %i[manifest vite controller layout streaming legacy_constant serialize_only flight_middleware].freeze
    # Built via Array#join so the gem-CI `name-propagation` guard does not
    # match these literals against itself (Story 5.1 review F4 — the doctor
    # file participates in the guard with no exclusion).
    LEGACY_CONST = %w[Rails Rsc].join
    LEGACY_GEM   = %w[rails rsc].join("_")
    LEGACY_CONSTANT_RE = /(?<![A-Za-z_])(?:#{LEGACY_CONST}|#{LEGACY_GEM})(?![A-Za-z_])/
    LEGACY_SCAN_GLOBS = ["config/initializers/**/*.rb", "app/**/*.rb"].freeze
    RENAME_DOC_URL = "https://github.com/luizcg/ruact/blob/main/CHANGELOG.md#renamed"

    # --- Story 13.1: serialize-only invariant tripwire (FR97) ---------------
    #
    # ruact EMITS React Flight (`text/x-component`) but must never DESERIALIZE
    # externally-supplied Flight into live Ruby objects — that keeps it outside
    # the React2Shell / CVE-2025-55182 class (a Flight-deserialization RCE). See
    # the ADR addendum in docs/internal/decisions/server-functions-api.md.
    #
    # The signal literals are assembled from fragments via Array#join so this
    # file does NOT itself contain the matched strings (mirrors the LEGACY_CONST
    # F4 lesson). `doctor.rb` is also excluded from the scan as defense in depth.
    # Only structural inbound-deserialization signals are used; the raw
    # `text/x-component` token is deliberately NOT a signal because the gem
    # legitimately EMITS that media type (controller.rb / server.rb) — matching
    # it would false-fail the current, invariant-holding tree.
    DESERIALIZE_SIGNALS = [
      # a `Deserializer` constant reference (FlightDeserializer, Flight::Deserializer, …);
      # matched as a substring so both the joined and namespaced forms trip it
      /#{%w[Deser ializer].join}/,
      # methods that turn inbound Flight into Ruby objects
      /\b#{%w[deserialize flight].join('_')}\b/,
      /\b#{%w[from flight].join('_')}\b/,
      /\b#{%w[parse flight].join('_')}\b/,
      /\b#{%w[decode flight].join('_')}\b/,
      # React Flight reader entry points invoked from Ruby (NOT createFromFlightPayload,
      # which is the client/browser deserializing the server's own trusted payload)
      /\b#{%w[create From].join}(?:NodeStream|ReadableStream|Fetch)\b/
    ].freeze
    DESERIALIZE_SIGNAL_RE = Regexp.union(DESERIALIZE_SIGNALS)
    # A line carrying this annotation is a deliberate, reviewed deserializer and
    # is treated as guarded (the check is a guard, not a blanket ban).
    ALLOW_FLIGHT_DESERIALIZATION = ["# ruact:allow", "flight", "deserialization"].join("-")
    # Exclude THIS file by its exact path (not basename) — its comments contain
    # the literal `Deserializer` example, so it must not match its own scan; but
    # a differently-located future file also named `doctor.rb` must still be
    # scanned (review finding R1 — basename exclusion was too broad).
    DOCTOR_FILE = File.expand_path(__FILE__)
    SERIALIZE_ONLY_DOC = "docs/internal/decisions/server-functions-api.md (serialize-only invariant, FR97)"

    # Response-transforming middleware that can mutate/recompress a streamed
    # `text/x-component` Flight body and break the wire contract (React-on-Rails
    # ops lesson). Matched by class name so the check needs no hard dependency.
    RESPONSE_TRANSFORMING_MIDDLEWARE = %w[Rack::Deflater].freeze

    # Statuses that do NOT fail the run. Anything else (including a malformed /
    # future status) is treated as a failure (review finding R1).
    SUCCESS_STATUSES = %i[pass warn].freeze

    # @param serialize_only_root [String] directory whose `**/*.rb` is scanned
    #   for the serialize-only tripwire. Defaults to the gem's own `lib/`;
    #   injectable so specs can point it at a fixture tree.
    def initialize(serialize_only_root: File.join(Ruact.gem_path, "lib"))
      @serialize_only_root = serialize_only_root
    end

    # Runs all checks, prints results, returns true if none FAIL.
    def self.run
      new.run
    end

    def run
      puts "[ruact] Health check"
      results = CHECKS.map { |check| send(:"check_#{check}") }
      results.each { |status, message| puts format_result(status, message) }
      # A :warn must NOT fail the run (Story 13.1 AC3); only :pass / :warn are
      # success. An unexpected status (rendered `✗`) fails loudly rather than
      # being silently treated as a pass (review finding R1).
      passed = results.all? { |status, _| SUCCESS_STATUSES.include?(status) }
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

    # Detects host-app references to the legacy gem constant or require path
    # left over from the rename to `ruact`. Literal names are interpolated
    # from LEGACY_CONST / LEGACY_GEM so this file passes the gem-CI
    # `name-propagation` guard without an exclusion (Story 5.1 review F4).
    def check_legacy_constant
      offenses = LEGACY_SCAN_GLOBS.flat_map do |glob|
        Dir[Rails.root.join(glob)].flat_map do |file|
          File.foreach(file).with_index(1).filter_map do |line, lineno|
            next unless LEGACY_CONSTANT_RE.match?(line)

            "#{file}:#{lineno}"
          end
        end
      end
      return [:pass, "No legacy `#{LEGACY_CONST}` / `#{LEGACY_GEM}` references found"] if offenses.empty?

      [:fail,
       "Legacy `#{LEGACY_CONST}` / `#{LEGACY_GEM}` references found in #{offenses.length} location(s) " \
       "(first: #{offenses.first}). Replace `#{LEGACY_CONST}` with `Ruact` and " \
       "`require \"#{LEGACY_GEM}\"` with `require \"ruact\"` (gem renamed in v0.0.x). " \
       "See #{RENAME_DOC_URL}."]
    end

    # Story 13.1 (AC2) — fails when ruact's OWN Ruby source introduces an
    # inbound Flight-deserialization entry point that is not explicitly
    # annotated `# ruact:allow-flight-deserialization <reason>`. Passes silently
    # when none exists (the current tree). Scans `@serialize_only_root/**/*.rb`,
    # excluding this file and the generators' client-side templates.
    def check_serialize_only
      offenses = Dir[File.join(@serialize_only_root, "**", "*.rb")].flat_map do |file|
        next [] if File.expand_path(file) == DOCTOR_FILE
        next [] if file.match?(%r{/generators/.+/templates/})

        File.foreach(file).with_index(1).filter_map do |line, lineno|
          next unless DESERIALIZE_SIGNAL_RE.match?(line)
          next if line.include?(ALLOW_FLIGHT_DESERIALIZATION)

          "#{file}:#{lineno}"
        end
      end

      if offenses.empty?
        return [:pass, "Serialize-only invariant holds — no inbound Flight deserializer in ruact's Ruby source"]
      end

      [:fail,
       "Inbound Flight deserializer entry point found in #{offenses.length} location(s) " \
       "(first: #{offenses.first}). ruact is serialize-only: it may emit `text/x-component` " \
       "but must never deserialize externally-supplied Flight into live Ruby objects " \
       "(React2Shell / CVE-2025-55182 class). Remove it, or — if deliberate and reviewed — " \
       "annotate the line with `#{ALLOW_FLIGHT_DESERIALIZATION} <reason>`. See #{SERIALIZE_ONLY_DOC}."]
    end

    # Story 13.1 (AC3) — WARNS (never fails) when a response-transforming
    # middleware is mounted in the app's stack, since it may recompress/mutate a
    # streamed `text/x-component` Flight body and break the wire contract.
    def check_flight_middleware
      stack = flight_middleware_stack
      return [:pass, "No response-transforming middleware on the Flight wire path"] if stack.nil?

      present = stack.filter_map { |mw| middleware_name(mw) }
                     .select { |name| RESPONSE_TRANSFORMING_MIDDLEWARE.include?(name) }
                     .uniq
      return [:pass, "No response-transforming middleware on the Flight wire path"] if present.empty?

      [:warn,
       "#{present.join(', ')} is mounted and may transform `text/x-component` (Flight) responses, " \
       "breaking the wire contract / streaming. Exclude Flight responses from compression " \
       "(don't compress `text/x-component`) or mount it so it does not wrap the Flight routes."]
    end

    # Returns the app middleware stack to scan, or nil when unavailable (no
    # Rails application present — e.g. the non-Rails / full-stub edge context).
    # At real `rails ruact:doctor` time the `:environment` task has booted the
    # app, so `app.middleware` is the enumerable `ActionDispatch::MiddlewareStack`.
    # Before `initialize!` it is a `Rails::Configuration::MiddlewareStackProxy`
    # (not enumerable) — skip it rather than crash on `filter_map`.
    def flight_middleware_stack
      return nil unless defined?(Rails) && Rails.respond_to?(:application)

      app = Rails.application
      return nil unless app.respond_to?(:middleware)

      stack = app.middleware
      stack.respond_to?(:each) ? stack : nil
    end

    def middleware_name(middleware)
      middleware.respond_to?(:name) ? middleware.name : middleware.to_s
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
      case status
      when :pass then "✓ #{message}"
      when :warn then "⚠ #{message}"
      else            "✗ #{message}"
      end
    end
  end
end
