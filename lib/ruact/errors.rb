# frozen_string_literal: true

module Ruact
  class Error < StandardError; end

  # Raised when react-client-manifest.json is absent or a component is not found in it.
  class ManifestError < Error; end

  # Raised when a Ruby value cannot be serialized as a React prop.
  class SerializationError < Error; end

  # Raised when the ERB preprocessor encounters a malformed component tag.
  class PreprocessorError < Error; end

  # Raised when application code attempts to mutate Ruact::Configuration outside
  # of a Ruact.configure block. The configuration is frozen after initialization
  # to prevent runtime drift; see Story 7.3 for the rationale and the decision
  # note for guidance on when re-configuration at runtime is appropriate.
  class ConfigurationError < Error; end

  # Raised by `Ruact::HtmlConverter.convert` when its input is not a `String`
  # (the only accepted shape). Catches the most common upstream bug — an ERB
  # template, partial, or render path that returned `nil` or a non-String value
  # — at the boundary, before Nokogiri is invoked, so the failing file:line and
  # the expected shape are visible at the top of the backtrace instead of
  # buried under a Nokogiri stack. See Story 7.4 for the rationale.
  class HtmlConverterError < Error; end

  # Story 8.3 — raised by a standalone server-action block (a module that
  # `extend`s {Ruact::ServerAction}) when its body invokes
  # {Ruact::ServerFunctions::StandaloneContext#current_user} but no
  # {Ruact::Configuration#current_user_resolver} has been configured. The
  # message names both worked examples (Devise + hand-rolled session) so
  # the developer can wire the resolver without leaving the stack trace.
  class CurrentUserNotConfiguredError < Error
    DEFAULT_MESSAGE = "Ruact.current_user requires Ruact.config.current_user_resolver to be set. " \
                      "Example (Devise): Ruact.configure { |c| c.current_user_resolver = ->(env) { env['warden']&.user } }. " \
                      "Example (hand-rolled session): Ruact.configure { |c| c.current_user_resolver = " \
                      "->(env) { User.find_by(id: env['rack.session'][:user_id]) } }."

    def initialize(message = DEFAULT_MESSAGE)
      super
    end
  end

  # Story 8.3 — raised inside a standalone server-action block to surface a
  # non-2xx response without calling `render` (which the StandaloneContext
  # does not expose). The endpoint dispatcher rescues this exception class
  # and renders `status` + `body` verbatim, mirroring how a controller-hosted
  # action would call `render(json: ..., status: ...)`.
  class ActionError < Error
    attr_reader :status, :body

    # @param status [Symbol, Integer] HTTP status (e.g. :unprocessable_entity, 422).
    # @param body [Object] the response payload. Hash/Array/scalar values are
    #   rendered as JSON; nil renders an empty body.
    # @param message [String] optional message; defaults to "ruact action error
    #   (status=<status>)" so the exception is still legible in logs.
    def initialize(status:, body: nil, message: nil)
      @status = status
      @body = body
      super(message || "ruact action error (status=#{status.inspect})")
    end
  end

  # Story 9.5 (FR88) — raised by the query dispatch controller when a
  # `useQuery` request's parameters violate the kwargs allowlist: a complex
  # value (array / object) where only `string | number | boolean | null` is
  # accepted, a missing required keyword, or an unknown parameter that matches
  # no declared kwarg. Inherits from `Ruact::Error` so the Story 8.4
  # `rescue_from StandardError` chain on the dispatch controller catches it
  # cleanly; `__ruact_status_for` maps it to HTTP 400 (Bad Request). The
  # message names the offending key and the allowlist so the React dev can
  # fix the call site without reading the server source.
  class BadRequestError < Error; end

  # Story 8.5 — raised by `EndpointController#__ruact_enforce_upload_limit!`
  # when an inbound multipart / urlencoded request's `Content-Length` exceeds
  # `Ruact.config.max_upload_bytes`. The exception inherits from
  # `Ruact::Error` so the Story 8.4 `rescue_from StandardError` chain on
  # `EndpointController` catches it cleanly; the endpoint controller's
  # `__ruact_status_for` maps it to HTTP 413, and `ErrorPayload.build`
  # extracts the `received_bytes` / `limit_bytes` pair into a dev-only
  # `upload_limit` block alongside the four baseline keys.
  #
  # The pair is exposed as `attr_reader` so the structured payload (and host
  # log lines) can show both numbers without re-parsing the message string.
  # Numbers report the WIRE `Content-Length` (which includes multipart
  # boundary overhead — a 9.5 MB file uploaded via multipart will report a
  # `received_bytes` slightly larger than the file size), not the parsed
  # file size — that's what the guard checks, and reporting the same number
  # avoids "why does the error say 9.7 MB when my file is 9.5 MB?" surprise.
  #
  # @example Construction shape (matches how the guard raises)
  #   raise Ruact::UploadTooLargeError.new(
  #     received_bytes: request.content_length,
  #     limit_bytes:    Ruact.config.max_upload_bytes
  #   )
  class UploadTooLargeError < Error
    attr_reader :received_bytes, :limit_bytes

    # @param received_bytes [Integer] wire `Content-Length` of the rejected request.
    # @param limit_bytes [Integer] configured `Ruact.config.max_upload_bytes` at reject time.
    # @param message [String] optional override; defaults to a string that
    #   names both numbers so the exception is legible without consulting
    #   the attr_readers.
    def initialize(received_bytes:, limit_bytes:, message: nil)
      @received_bytes = received_bytes
      @limit_bytes = limit_bytes
      super(message || "Upload exceeded the configured size limit " \
                       "(received_bytes=#{received_bytes}, limit_bytes=#{limit_bytes})")
    end
  end
end
