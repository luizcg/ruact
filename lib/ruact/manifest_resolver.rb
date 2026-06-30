# frozen_string_literal: true

require "json"

module Ruact
  # Resolves the {Ruact::ClientManifest} to use for the current render /
  # ERB-preprocess.
  #
  # PRODUCTION (unchanged): returns the boot-loaded +Ruact.manifest+ (set once by
  # the Railtie's +config.to_prepare+; the Railtie raises at boot when the file is
  # absent). No per-request I/O.
  #
  # DEVELOPMENT (the fix): the boot-time +to_prepare+ read of
  # +public/react-client-manifest.json+ RACES the Vite dev server's first write —
  # on a fresh app Rails can boot (and read the missing file) BEFORE Vite writes
  # it, leaving +Ruact.manifest+ nil even though Vite is running and serving a
  # current manifest. +public/+ is not watched, so +to_prepare+ never re-fires and
  # the first request to a view with a component hits +nil.reference_for+ → 500.
  #
  # To kill that race, dev resolution fetches the LIVE manifest the Vite plugin
  # serves in memory at +GET {vite_dev_server}/__ruact/manifest+ (always fresh,
  # reflects HMR rebuilds), with graceful fallbacks:
  #
  #   1. HTTP fetch from the Vite dev server (short timeout).
  #   2. Fallback: read +public/react-client-manifest.json+ from disk (the Vite
  #      plugin still writes it — prod needs it for the build, and it is the
  #      fallback when the dev server is down).
  #   3. Neither available → a clear, actionable error (never a cryptic
  #      +NoMethodError+ on nil).
  #
  # Memoization grain: the resolver fetches ONCE PER CALL. The two call sites each
  # invoke it once per their scope and reuse the result for every component —
  # +RenderPipeline+ holds the returned manifest in +@manifest+ for the whole
  # render, and +ErbPreprocessor#transform+ resolves it lazily into a local that
  # is reused across every tag in the template. So a render does NOT re-fetch per
  # component (the bug was many +reference_for+ calls all needing a manifest); at
  # most one fetch for the render and one for a (re)compiled template.
  module ManifestResolver
    DEV_MANIFEST_PATH = "/__ruact/manifest"
    # Dev is localhost; fail fast to the file/clear-error fallback. A refused
    # connection (Vite simply down) raises immediately, so this timeout only
    # bounds the pathological "listening but not answering" case.
    HTTP_OPEN_TIMEOUT = 1
    HTTP_READ_TIMEOUT = 1

    # Resolve the manifest for a render. In dev, raises a clear
    # {Ruact::ManifestError} when neither the dev server nor the on-disk file is
    # available. In any non-development environment, returns +Ruact.manifest+
    # verbatim (production behaviour is untouched).
    #
    # @return [Ruact::ClientManifest, nil]
    def self.resolve
      return Ruact.manifest unless development?

      dev_manifest(soft: false)
    end

    # Like {.resolve} but FAIL-OPEN in dev: returns +nil+ (rather than raising)
    # when nothing is resolvable. Used by the ERB preprocessor's opt-in FR100
    # contract validation, which is fail-open by design — a missing manifest must
    # not crash template compilation; the render path then surfaces the clear
    # error from {.resolve}.
    #
    # @return [Ruact::ClientManifest, nil]
    def self.resolve_soft
      return Ruact.manifest unless development?

      dev_manifest(soft: true)
    end

    # @return [Ruact::ClientManifest, nil]
    def self.dev_manifest(soft:)
      manifest = fetch_over_http
      return manifest if manifest

      manifest = load_from_file
      return manifest if manifest

      return nil if soft

      raise ManifestError, <<~MSG.strip
        [ruact] Vite dev server inacessível em #{base_url} e nenhum \
        react-client-manifest.json encontrado em #{file_path} — rode `bin/dev`.
      MSG
    end

    # Fetch + parse the live manifest from the Vite dev server, or +nil+ when the
    # server is unreachable / returns a non-200 / unparseable body. Never raises:
    # any failure degrades to the file fallback.
    #
    # @return [Ruact::ClientManifest, nil]
    def self.fetch_over_http
      require "net/http"
      require "uri"

      # `chomp("/")` so a base configured WITH a trailing slash
      # ("http://localhost:5173/") does not yield a double-slashed
      # "//__ruact/manifest" that misses the Vite middleware mount.
      uri = URI.parse("#{base_url.chomp('/')}#{DEV_MANIFEST_PATH}")
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT
      ) { |http| http.get(uri.request_uri) }

      return nil unless response.is_a?(Net::HTTPSuccess)

      ClientManifest.from_hash(JSON.parse(response.body))
    rescue StandardError
      nil
    end

    # Fallback: load the on-disk manifest the Vite plugin also writes, or +nil+
    # when it is absent (the boot-race window) / unreadable.
    #
    # @return [Ruact::ClientManifest, nil]
    def self.load_from_file
      path = file_path
      return nil unless path && File.exist?(path)

      ClientManifest.load(path)
    rescue StandardError
      nil
    end

    # @return [String] the configured Vite dev-server base URL.
    def self.base_url
      Ruact.config.vite_dev_server
    end

    # @return [String, nil] the on-disk manifest path (config override or default).
    def self.file_path
      configured = Ruact.config.manifest_path
      return configured.to_s if configured

      return nil unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      Rails.root.join("public", "react-client-manifest.json").to_s
    end

    # @return [Boolean] true only in a real Rails development environment. Any
    #   other env (production, test, or no Rails at all) takes the untouched
    #   +Ruact.manifest+ path.
    def self.development?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:development?) &&
        Rails.env.development?
    end
  end
end
