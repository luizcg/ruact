# frozen_string_literal: true

require "json"
require "time"

module Ruact
  module ServerFunctions
    # Pure functions that build the JSON-shaped Hash representing both server-
    # function registries. Serialized to `tmp/cache/ruact/server-functions.json`
    # by {.generate!}; the Vite plugin reads that file and emits the TS module.
    #
    # The "functions" array is sorted by `ruby_symbol` for deterministic output
    # so that fingerprint comparisons (used by the write-if-changed guard) are
    # stable across runs.
    module Snapshot
      # Bump only when the on-disk schema changes incompatibly. The Vite plugin
      # must be updated in lockstep.
      VERSION = 1

      class << self
        # Builds the snapshot Hash for both registries. Pure. See also
        # {.generate!} (writes to disk) and {.functions_payload} (fingerprint
        # surface).
        #
        # @param action_registry [Ruact::ServerFunctions::Registry]
        # @param query_registry  [Ruact::ServerFunctions::Registry]
        # @param now [Time] timestamp to stamp into `generated_at` (UTC, ISO-8601).
        # @return [Hash] the serializable snapshot.
        def dump(action_registry, query_registry, now: Time.now.utc)
          {
            version: VERSION,
            generated_at: now.utc.iso8601,
            functions: functions_payload(action_registry, query_registry)
          }
        end

        # Returns the payload-only array of function entries, sorted by
        # `ruby_symbol`. Used both inside {.dump} and as the fingerprint surface
        # by {.generate!}'s short-circuit (so timestamp churn alone never causes
        # a rewrite).
        #
        # @return [Array<Hash>] each entry has string keys per the JSON contract.
        def functions_payload(action_registry, query_registry)
          combined = action_registry.entries.values + query_registry.entries.values
          combined.sort_by { |entry| entry.ruby_symbol.to_s }.map do |entry|
            {
              "ruby_symbol" => entry.ruby_symbol.to_s,
              "js_identifier" => entry.js_identifier,
              "kind" => entry.kind.to_s,
              "controller" => describe_controller(entry.controller)
            }
          end
        end

        # Builds the snapshot and writes it to +path+, but only if the
        # functions list differs from the on-disk snapshot. This is the central
        # short-circuit that prevents `config.to_prepare` from rewriting the
        # file on every request (Story 8.0a pitfall #1): the JSON's
        # `generated_at` is freshly stamped only when the registry actually
        # changed; otherwise the on-disk content stays byte-identical.
        #
        # @param action_registry [Ruact::ServerFunctions::Registry]
        # @param query_registry  [Ruact::ServerFunctions::Registry]
        # @param path [String, Pathname] absolute path to the snapshot JSON.
        # @param now [Time] timestamp used when (and only when) the file is rewritten.
        # @return [Boolean] true if the file was written; false if no change.
        def generate!(action_registry:, query_registry:, path:, now: Time.now.utc)
          new_functions = functions_payload(action_registry, query_registry)

          if File.exist?(path)
            existing = parse_existing_payload(path)
            return false if existing == new_functions
          end

          snapshot = {
            version: VERSION,
            generated_at: now.utc.iso8601,
            functions: new_functions
          }
          SnapshotWriter.write_if_changed!(path: path, content: "#{JSON.pretty_generate(snapshot)}\n")
        end

        private

        def describe_controller(controller)
          return nil if controller.nil?

          controller.respond_to?(:name) && controller.name ? controller.name : controller.inspect
        end

        def parse_existing_payload(path)
          parsed = JSON.parse(File.read(path))
          parsed.is_a?(Hash) ? parsed["functions"] : nil
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
