# frozen_string_literal: true

require "fileutils"
require "digest"

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
          return false if File.exist?(path) && File.read(path) == content

          dir = File.dirname(path)
          ensure_writable!(dir)

          tmp = "#{path}.tmp.#{Process.pid}.#{Digest::SHA256.hexdigest(content)[0, 8]}"
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
