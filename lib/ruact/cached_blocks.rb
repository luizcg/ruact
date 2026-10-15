# frozen_string_literal: true

module Ruact
  # Story 19-2 — a render that renders `<Suspense>` content in place writes no
  # block marker: one in its HTML came out of a `cache` block a render that
  # streamed wrote. Its boundary gets an error row ({Flight::Renderer}); this
  # says so on the server, as {DeferredRender} does for a render that streams.
  #
  # Internal API: not part of the public compatibility contract.
  module CachedBlocks
    # Only the attribute as written in a tag (`="`): text that mentions it is
    # escaped.
    MARKER = %( #{Markers::BLOCK_ATTR}=").freeze
    private_constant :MARKER

    # Logs and reports a block marker in +html+.
    #
    # @param html [String]
    # @param logger [Logger, nil]
    # @return [void]
    def self.report(html, logger)
      return unless html.include?(MARKER)

      error = Ruact::Error.new(Flight::DeferredContent::STALE)
      logger&.error("[ruact] #{error.message}")
      Rails.error.report(error, handled: true, severity: :error, source: "ruact.suspense") if
        defined?(Rails) && Rails.respond_to?(:error)
    end
  end
end
