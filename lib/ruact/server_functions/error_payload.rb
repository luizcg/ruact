# frozen_string_literal: true

require_relative "backtrace_cleaner"
require_relative "error_suggestion"

module Ruact
  module ServerFunctions
    # Story 8.4 — Builds the structured JSON body returned by
    # {EndpointController#__ruact_render_action_error} for any server-action
    # exception that bubbles past a host's `rescue_from` chain.
    #
    # The function is pure (no `Rails.env`, no `Ruact.config` reads) — the
    # caller resolves `mode` (`:development` or `:production`) and passes it
    # in. That keeps the module trivially testable without stubbing Rails env.
    #
    # In `:development` mode the payload carries the full surface:
    # action name, error class, message, split backtrace (first 25 frames per
    # bucket), contextual suggestion, and (for `ActiveRecord::RecordInvalid`)
    # the model's `full_messages`.
    #
    # In `:production` mode the payload is reduced to four baseline keys:
    # `_ruact_server_action_error`, `action_name`, `error_class`, `message`.
    # React components can render their own UI from those four fields without
    # any accidental backtrace leakage on the wire.
    module ErrorPayload
      # Maximum frames preserved per bucket. The full backtrace is still in
      # the server log; the wire payload is for the overlay, which is
      # unreadable past a couple of dozen frames anyway.
      MAX_FRAMES_PER_BUCKET = 25

      # @param action_name [Symbol, String]
      # @param error [Exception]
      # @param mode [Symbol] :development or :production
      # @return [Hash{String=>Object}]
      def self.build(action_name:, error:, mode:)
        # Pitfall #5: defensive dup against frozen-string `Exception#message`
        # implementations.
        message = error.message.to_s.dup
        payload = {
          "_ruact_server_action_error" => true,
          "action_name" => action_name.to_s,
          "error_class" => error.class.name,
          "message" => message
        }
        return payload if mode == :production

        frames = BacktraceCleaner.split(error.backtrace)
        payload["app_frames"] = frames[:app].first(MAX_FRAMES_PER_BUCKET)
        payload["gem_frames"] = frames[:gem].first(MAX_FRAMES_PER_BUCKET)
        payload["suggestion"] = ErrorSuggestion.for(error)
        validation_errors = extract_validation_errors(error)
        payload["validation_errors"] = validation_errors if validation_errors
        upload_limit = extract_upload_limit(error)
        payload["upload_limit"] = upload_limit if upload_limit
        payload
      end

      # Story 8.5 — for `Ruact::UploadTooLargeError`, surface the
      # `received_bytes` / `limit_bytes` pair as a dev-only block so the
      # overlay can render both numbers without re-parsing the message.
      # Returns nil for any other error class so the caller can omit the
      # key entirely (preserves the "four baseline keys" prod contract).
      def self.extract_upload_limit(error)
        return nil unless error.class.name == "Ruact::UploadTooLargeError"

        {
          "received_bytes" => error.received_bytes,
          "limit_bytes" => error.limit_bytes
        }
      end
      private_class_method :extract_upload_limit

      # Returns `full_messages` for `ActiveRecord::RecordInvalid` (or any
      # error that exposes `.record.errors.full_messages`); `[]` when the
      # record is nil; `nil` for unrelated exception classes (so the caller
      # can omit the key entirely).
      def self.extract_validation_errors(error)
        return nil unless error.class.name == "ActiveRecord::RecordInvalid"
        return [] unless error.respond_to?(:record)

        record = error.record
        return [] if record.nil?
        return [] unless record.respond_to?(:errors)

        errors = record.errors
        return [] unless errors.respond_to?(:full_messages)

        errors.full_messages.to_a
      end
      private_class_method :extract_validation_errors
    end
  end
end
