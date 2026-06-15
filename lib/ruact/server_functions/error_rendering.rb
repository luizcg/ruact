# frozen_string_literal: true

require_relative "error_payload"

module Ruact
  module ServerFunctions
    # Story 9.1 — the shared core for the Story 8.4 structured-error rendering
    # and the Story 8.5 upload guard, included by {Ruact::Server} (the
    # route-driven concern hosts include). Story 9.9 demolished the v1 endpoint
    # that previously shared this code, so {Ruact::Server} is now the sole home.
    #
    # Behavioral specialization is expressed through three private hooks, which
    # the including controller may override:
    #
    #   - {#__ruact_error_action_name} — where the payload's `action_name`
    #     comes from. Default: the controller's own `action_name`.
    #   - {#__ruact_render_structured_error?} — whether the rescue handler
    #     renders the structured JSON payload for this request, or re-raises so
    #     Rails' default error handling proceeds. {Ruact::Server} gates this on
    #     its function-call predicate.
    #   - {#__ruact_upload_guard_applicable?} — whether the upload guard applies
    #     to this request at all. {Ruact::Server} skips GET/HEAD so page actions
    #     stay byte-for-byte untouched.
    #
    # All methods are private on the including controller; nothing here is
    # public API surface.
    module ErrorRendering
      private

      # Story 8.5 — `prepend_before_action` callback. Rejects requests whose
      # wire `Content-Length` exceeds `Ruact.config.max_upload_bytes`. The
      # check uses `Content-Length` (not body inspection) so it fires BEFORE
      # Rack's multipart parser would touch the body — the cheapest possible
      # reject. It only fires for `multipart/form-data` and
      # `application/x-www-form-urlencoded`; JSON bodies have their own
      # operational caps (host middleware / reverse proxy) and aren't a
      # "max upload" concern. Chunked-transfer clients (`Content-Length`
      # absent) bypass the guard because we cannot know the size up-front; the
      # action body is responsible for any belt-and-suspenders check via
      # `params[:file].size` / `params[:file].byte_size`. A nil
      # `Ruact.config.max_upload_bytes` short-circuits the guard entirely —
      # the gem-side knob has been opted out and the host's reverse proxy /
      # middleware owns the cap.
      #
      # The reported `received_bytes` is the WIRE Content-Length, which
      # includes multipart boundary overhead (a 9.5 MB file uploaded via
      # multipart reports `received_bytes ≈ 9.5 MB + a few KB`). The 10 MB
      # default has enough headroom that this is invisible for the common
      # case; the docs page calls it out for the edge.
      def __ruact_enforce_upload_limit!
        return unless __ruact_upload_guard_applicable?

        limit = Ruact.config.max_upload_bytes
        return if limit.nil?

        content_type = request.content_mime_type&.to_s
        return unless ["multipart/form-data", "application/x-www-form-urlencoded"].include?(content_type)

        received = request.content_length
        return if received.nil?
        return if received <= limit

        raise Ruact::UploadTooLargeError.new(received_bytes: received, limit_bytes: limit)
      end

      # Story 8.4 — Structured server-action error renderer. Resolves the
      # mode from {Ruact.config.dev_error_payload_enabled} (falling back to
      # `Rails.env.development? || Rails.env.test?` when nil), builds the
      # JSON body via {ErrorPayload.build}, logs the failure server-side
      # (always — the prod constraint is "do not leak via the wire", not
      # "do not log"), then renders `json: payload, status: <mapped>`.
      #
      # Story 9.1 — when {#__ruact_render_structured_error?} returns false
      # (a non-function-call request on a {Ruact::Server} host), the error is
      # re-raised instead: re-raising inside a `rescue_from` handler
      # propagates out of `process_action` without re-entering the rescue
      # chain (the handler IS the rescue clause), so Rails' default error
      # handling — debug page in development, public 500 in production —
      # proceeds exactly as if the concern were not installed.
      def __ruact_render_action_error(error)
        raise error unless __ruact_render_structured_error?(error)

        action_name = __ruact_error_action_name
        mode = __ruact_payload_mode
        payload = ErrorPayload.build(action_name: action_name, error: error, mode: mode)
        __ruact_log_action_error(action_name, error)
        render(json: payload, status: __ruact_status_for(error))
      end

      # Hook — where the structured payload's `action_name` field comes from.
      # The controller's own `action_name` is correct for host controllers
      # (it is populated by routing before any callback runs, including the
      # prepended upload guard — no early-rejection fallback dance needed).
      def __ruact_error_action_name
        action_name
      end

      # Hook — render the structured payload for this request? The default is
      # "always"; {Ruact::Server} overrides it to gate on its function-call
      # predicate (page/Flight requests re-raise so Rails' default error
      # handling proceeds untouched).
      def __ruact_render_structured_error?(_error)
        true
      end

      # Hook — does the upload guard apply to this request? The default is
      # "always"; {Ruact::Server} overrides it to skip GET/HEAD.
      def __ruact_upload_guard_applicable?
        true
      end

      # Story 8.4 — Status mapping per AC1:
      # - `Ruact::BadRequestError` → 400 (Story 9.5 — FR88 kwargs rejection)
      # - `ActiveRecord::RecordInvalid` → 422
      # - `ActionController::InvalidAuthenticityToken` → 403
      # - `Ruact::UploadTooLargeError` → 413
      # - any other StandardError → 500
      # Uses class-name string match so the gem does NOT require ActiveRecord
      # at load time (parity with {ErrorSuggestion}).
      def __ruact_status_for(error)
        case error.class.name
        when "Ruact::BadRequestError" then 400
        when "ActiveRecord::RecordInvalid" then 422
        when "ActionController::InvalidAuthenticityToken" then 403
        when "Ruact::UploadTooLargeError" then 413
        else 500
        end
      end

      # Story 8.4 — Resolve the payload mode from configuration with a Rails
      # env fallback. The fallback keeps the Configuration trivially
      # constructible in non-Rails specs while ensuring production hosts that
      # never call `Ruact.configure` still see the reduced wire shape.
      #
      # Strict-boolean handling (review follow-up): only the literals `true`
      # and `false` count as an explicit configuration. Any other value
      # (strings like `"true"`, numerics, Symbols, etc.) falls back to the
      # env-driven default rather than being coerced via Ruby truthiness —
      # otherwise a misconfigured `c.dev_error_payload_enabled = "false"`
      # would silently leak the verbose payload in production.
      def __ruact_payload_mode
        case Ruact.config.dev_error_payload_enabled
        when true  then :development
        when false then :production
        else __ruact_default_dev_mode? ? :development : :production
        end
      end

      def __ruact_default_dev_mode?
        return false unless defined?(Rails) && Rails.respond_to?(:env)

        Rails.env.development? || Rails.env.test?
      end

      # Story 8.4 AC6 — log a single error line + the full backtrace, both at
      # `error` severity. When `Rails.logger` responds to `tagged` (the
      # ActiveSupport::TaggedLogging extension; Rails 6+ default for the
      # request logger), wrap the entry in a `ruact action:<name>` tag for
      # log-aggregator indexing. The full backtrace is emitted regardless of
      # the wire-payload mode — server-side logs always carry the full
      # picture.
      def __ruact_log_action_error(action_name, error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        line = "[ruact] server action :#{action_name} failed — #{error.class.name}: #{error.message}"
        backtrace_text = Array(error.backtrace).join("\n")

        logger = Rails.logger
        if logger.respond_to?(:tagged)
          logger.tagged("ruact action:#{action_name}") do
            logger.error(line)
            logger.error(backtrace_text) unless backtrace_text.empty?
          end
        else
          logger.error(line)
          logger.error(backtrace_text) unless backtrace_text.empty?
        end
      end
    end
  end
end
