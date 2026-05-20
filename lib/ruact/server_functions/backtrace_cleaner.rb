# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 8.4 — Splits an exception backtrace into application frames and
    # gem-internal frames so the dev overlay can hide gem frames behind a
    # toggle by default while still capturing them for the "Copy to clipboard"
    # affordance.
    #
    # Pure function, no I/O. Anchors classification on {Ruact.gem_path} which
    # is memoised at gem load time; the per-frame `start_with?` check is
    # therefore constant-time.
    #
    # Deliberately NOT a thin wrapper over `ActiveSupport::BacktraceCleaner` —
    # that class's silencer/filter API is heavyweight for this single-purpose
    # need; this module is ~10 LoC with zero ActiveSupport dependency so it
    # loads cleanly in AR-less specs (see Pitfall #4 in the story).
    module BacktraceCleaner
      # Split a raw backtrace into app and gem buckets.
      #
      # @param backtrace [Array<String>, nil] frames from `Exception#backtrace`
      # @return [Hash{Symbol=>Array<String>}] `{ app: [...], gem: [...] }`
      def self.split(backtrace)
        return { app: [], gem: [] } if backtrace.nil? || backtrace.empty?

        gem_prefix = Ruact.gem_path
        gem_frames, app_frames = backtrace.partition { |frame| frame.start_with?(gem_prefix) }
        { app: app_frames, gem: gem_frames }
      end
    end
  end
end
