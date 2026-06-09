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
    # stable across runs. Cross-registry JS-identifier collisions are detected
    # here (the per-registry `Registry#register` only sees its own entries; a
    # `ruact_action :foo` colliding with a `ruact_query :foo` is invisible to
    # both registries in isolation).
    module Snapshot
      # Bump only when the on-disk schema changes incompatibly. The Vite plugin
      # must be updated in lockstep.
      VERSION = 1

      # Story 9.3 — the route-driven snapshot schema. v2 entries are produced by
      # {Ruact::ServerFunctions::RouteSource} (route table), not the registries.
      VERSION_V2 = 2

      class << self
        # Builds the snapshot Hash for both registries. Pure. See also
        # {.generate!} (writes to disk) and {.functions_payload} (fingerprint
        # surface).
        #
        # @param action_registry [Ruact::ServerFunctions::Registry]
        # @param query_registry  [Ruact::ServerFunctions::Registry]
        # @param now [Time] timestamp to stamp into `generated_at` (UTC, ISO-8601).
        # @return [Hash] the serializable snapshot.
        # @raise [Ruact::ConfigurationError] when a JS identifier is registered
        #   in both registries (cross-registry collision; see {.functions_payload}).
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
        # a rewrite). Detects cross-registry JS-identifier collisions and
        # raises before emitting — a `ruact_action :foo` and `ruact_query :foo`
        # would emit two `export const foo` lines at codegen, which `tsc` rejects.
        #
        # @return [Array<Hash>] each entry has string keys per the JSON contract.
        # @raise [Ruact::ConfigurationError] when the action and query registries
        #   both contain entries that map to the same JS identifier.
        def functions_payload(action_registry, query_registry)
          combined = action_registry.entries.values + query_registry.entries.values
          detect_cross_registry_collision!(combined)
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
        # The short-circuit compares **both** `version` and `functions` against
        # the on-disk snapshot — a schema bump (`VERSION` increment) forces a
        # rewrite even when the registry payload is unchanged, so the Vite
        # plugin never reads a stale-version snapshot after a gem upgrade.
        #
        # @param action_registry [Ruact::ServerFunctions::Registry]
        # @param query_registry  [Ruact::ServerFunctions::Registry]
        # @param path [String, Pathname] absolute path to the snapshot JSON.
        # @param now [Time] timestamp used when (and only when) the file is rewritten.
        # @return [Boolean] true if the file was written; false if no change.
        def generate!(action_registry:, query_registry:, path:, now: Time.now.utc)
          new_functions = functions_payload(action_registry, query_registry)

          existing_version, existing_functions = read_existing_snapshot(path)
          return false if existing_version == VERSION && existing_functions == new_functions

          snapshot = {
            version: VERSION,
            generated_at: now.utc.iso8601,
            functions: new_functions
          }
          SnapshotWriter.write_if_changed!(path: path, content: "#{JSON.pretty_generate(snapshot)}\n")
        end

        # Story 9.3 — wraps route-derived +entries+ into a version-2 snapshot
        # Hash (the shape {Codegen.render} dispatches on). Pure.
        #
        # @param entries [Array<Hash>] from {RouteSource.collect}.
        # @return [Hash]
        def dump_v2(entries, now: Time.now.utc)
          {
            version: VERSION_V2,
            generated_at: now.utc.iso8601,
            functions: entries
          }
        end

        # Story 9.3 — write-if-changed for the route-driven (v2) bridge. Mirrors
        # {.generate!}: `generated_at` is freshly stamped only when the entries
        # changed, so a stable route table never churns the file (and never
        # re-triggers downstream TS rendering). A schema mismatch (`version`)
        # forces a rewrite even when entries are unchanged.
        #
        # @param entries [Array<Hash>] from {RouteSource.collect}.
        # @param path [String, Pathname] absolute path to the v2 bridge JSON.
        # @return [Boolean] true if written, false if unchanged.
        def generate_v2!(entries:, path:, now: Time.now.utc)
          existing_version, existing_functions = read_existing_snapshot(path)
          return false if existing_version == VERSION_V2 && existing_functions == entries

          snapshot = { version: VERSION_V2, generated_at: now.utc.iso8601, functions: entries }
          SnapshotWriter.write_if_changed!(path: path, content: "#{JSON.pretty_generate(snapshot)}\n")
        end

        # Story 9.3 — the Decision-#6 ownership primitive. True when the app has
        # ANY v1 declaration (`ruact_action` / `ruact_query`). Story 9.8 consults
        # this to decide whether route-driven codegen takes over the real
        # `server-functions.ts`; in Story 9.3 the v2 codegen always writes the
        # parallel `.next` target regardless, so this is informational here.
        #
        # @return [Boolean]
        def v1_declarations?(action_registry, query_registry)
          !(action_registry.entries.empty? && query_registry.entries.empty?)
        end

        private

        def detect_cross_registry_collision!(entries)
          by_js_id = entries.group_by(&:js_identifier).select { |_, group| group.size >= 2 }
          return if by_js_id.empty?

          # If both rows are the same Ruby symbol it is a within-registry duplicate
          # (caught by Registry#register's own collision detection). A genuine
          # cross-registry collision is any group whose entries span more than
          # one kind — i.e. one action + one query share the same js_identifier.
          cross = by_js_id.find do |_, group|
            kinds = group.map(&:kind).uniq
            kinds.size > 1
          end
          return unless cross

          js_id, group = cross
          # AC7 exact shape: `:foo_bar (in FooController) and :foo__bar (in BarController)`
          # — no `kind:` annotation. The kind differentiation is implicit in
          # the cross-registry collision being detected at all.
          parts = group.map do |entry|
            ":#{entry.ruby_symbol} (in #{describe_controller(entry.controller)})"
          end
          # AC7 shape: "[ruact] error: server-function naming collision: ..."
          # The rake task wraps the bare message with "[ruact] error: " — keep
          # the prefix in sync with the within-registry message in
          # Registry#detect_collision! so the rake stdout reads identically
          # for both kinds of collision.
          raise Ruact::ConfigurationError,
                "server-function naming collision: " \
                "#{parts.join(' and ')} both map to JS identifier \"#{js_id}\""
        end

        def describe_controller(controller)
          return nil if controller.nil?

          controller.respond_to?(:name) && controller.name ? controller.name : controller.inspect
        end

        # Reads `(version, functions)` from the on-disk snapshot. Returns
        # `[nil, nil]` when the file is missing, vanished between the stat and
        # the read (TOCTOU race fix — `File.exist?` removed; we catch `ENOENT`
        # from `File.read` directly), or malformed.
        def read_existing_snapshot(path)
          parsed = JSON.parse(File.read(path))
          return [nil, nil] unless parsed.is_a?(Hash)

          [parsed["version"], parsed["functions"]]
        rescue Errno::ENOENT, JSON::ParserError
          [nil, nil]
        end
      end
    end
  end
end
