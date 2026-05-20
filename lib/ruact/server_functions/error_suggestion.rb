# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 8.4 — Maps an exception class (by its String name) to a short
    # corrective suggestion shown in the dev overlay's structured view.
    #
    # The class-name match runs against `error.class.name` (a String) so the
    # module does NOT need `require "active_record"` or
    # `require "action_controller"` to operate; it works in AR-less specs and
    # bare-Rack hosts (see Pitfall #4 in the story).
    #
    # The {SUGGESTIONS} table is a gem-published surface — new entries land
    # via an ADR amendment + a constant update, NOT via runtime registration.
    module ErrorSuggestion
      SUGGESTIONS = {
        "ActiveRecord::RecordInvalid" =>
          "Validation failed — check the model's `validates` rules",
        "ActionController::InvalidAuthenticityToken" =>
          "CSRF token mismatch — ensure the page was rendered after the most recent server restart and the session cookie is intact"
      }.freeze

      # Suggestion string for the given error, or nil for unknown classes.
      #
      # @param error [Exception]
      # @return [String, nil]
      def self.for(error)
        SUGGESTIONS[error.class.name]
      end
    end
  end
end
