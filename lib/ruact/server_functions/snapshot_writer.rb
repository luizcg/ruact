# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Ruact
  module ServerFunctions
    # Atomic, byte-aware file writer used by both the JSON snapshot bridge and
    # the Ruby-side TypeScript codegen. Two responsibilities:
    #
    # 1. **Write-if-changed**: compare the SHA-256 of the desired bytes with the
    #    on-disk bytes; if equal, no-op. This is the leg of the dev-reload
    #    pitfall mitigation (Story 8.0a pitfall #1) — paired with the
    #    payload-only fingerprint inside `Snapshot.generate!`, it guarantees
    #    that a request without registry changes produces zero writes.
    # 2. **Atomic publication**: write to a tmpfile in the same directory, then
    #    rename. Readers (the Vite-plugin chokidar watcher) never observe a
    #    half-written file.
    #
    # Parent directories are created as needed.
    module SnapshotWriter
      class << self
        # @param path [String, Pathname] absolute destination path.
        # @param content [String] bytes to write.
        # @return [Boolean] true if the file was written; false if unchanged.
        # @raise [Ruact::ConfigurationError] when the parent directory cannot be
        #   created (typically a read-only filesystem mounted into the app).
        def write_if_changed!(path:, content:) # rubocop:disable Naming/PredicateMethod
          path = path.to_s
          # TOCTOU-safe read: catch `ENOENT` from `File.read` rather than
          # gating on `File.exist?` — between the stat and the read the file
          # may be removed by another process (e.g. `rails tmp:clear`).
          existing = begin
            File.read(path)
          rescue StandardError
            nil
          end
          return false if existing == content

          dir = File.dirname(path)
          ensure_writable!(dir)

          # Random suffix so two same-process writes of identical content do
          # not race over the same temp filename (e.g. JSON-snapshot writer
          # + Ruby TS codegen running back-to-back inside the rake task on
          # an unchanged registry — the digest-prefix-only tmp name was
          # deterministic, which collided).
          tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(8)}"
          File.binwrite(tmp, content)
          File.rename(tmp, path)
          true
        end

        private

        def ensure_writable!(dir)
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          raise Ruact::ConfigurationError,
                "ruact: cannot create #{dir} for server-functions snapshot: #{e.message}"
        end
      end
    end
  end
end
