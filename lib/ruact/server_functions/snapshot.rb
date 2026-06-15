# frozen_string_literal: true

require "json"
require "time"

module Ruact
  module ServerFunctions
    # Pure functions that build the JSON-shaped Hash representing the route-
    # driven server-function bridge. Serialized to
    # `tmp/cache/ruact/server-functions.json` by {.generate_v2!}; the Vite
    # plugin reads that file and emits the TS module.
    #
    # Story 9.9 — the v1 registry path was demolished; only the route-driven
    # (version-2) schema remains.
    module Snapshot
      # Story 9.3 — the route-driven snapshot schema. v2 entries are produced by
      # {Ruact::ServerFunctions::RouteSource} (route table), not registries.
      VERSION_V2 = 2

      class << self
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

        # Story 9.3 — write-if-changed for the route-driven (v2) bridge.
        # `generated_at` is freshly stamped only when the entries changed, so a
        # stable route table never churns the file (and never re-triggers
        # downstream TS rendering). A schema mismatch (`version`) forces a
        # rewrite even when entries are unchanged.
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

        private

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
