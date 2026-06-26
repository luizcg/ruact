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

  # Story 13.2 (FR96) — raised by `Ruact.locate_signed` when a SignedGlobalID
  # token fails verification: a tampered signature, an expired token, or a token
  # scoped to a different `for:` purpose (`GlobalID::Locator.locate_signed`
  # returns `nil`). Inherits from `Ruact::Error` so the Story 8.4
  # `rescue_from StandardError` chain catches it cleanly; `__ruact_status_for`
  # maps it to HTTP 400 (Bad Request) — a forged/expired reference is an
  # invalid credential the client supplied, NOT a missing record. This keeps
  # `ActiveRecord::RecordNotFound` from leaking and never reveals whether the
  # target record exists (verification fails before any DB lookup). A *valid*
  # token whose record was since deleted is NOT this error — the underlying
  # finder (`ActiveRecord::RecordNotFound`) propagates and is the host's normal
  # not-found concern, exactly as a raw `Model.find` would be.
  class InvalidSignedGlobalIDError < Error; end

  # Story 8.5 — raised by the `Ruact::Server` upload guard when an inbound
  # multipart / urlencoded request's `Content-Length` exceeds
  # `Ruact.config.max_upload_bytes`. The exception inherits from
  # `Ruact::Error` so the Story 8.4 `rescue_from StandardError` chain catches
  # it cleanly; `__ruact_status_for` maps it to HTTP 413, and
  # `ErrorPayload.build` extracts the `received_bytes` / `limit_bytes` pair
  # into a dev-only `upload_limit` block alongside the four baseline keys.
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
