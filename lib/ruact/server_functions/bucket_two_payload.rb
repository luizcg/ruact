# frozen_string_literal: true

require "date"
require_relative "../serializable"
require_relative "../errors"

module Ruact
  module ServerFunctions
    # Story 9.2 — pure serializer for the Bucket-2 (imperative `await fn()`)
    # response body. Takes the host action's exposed instance variables (Rails
    # `view_assigns`, resolved by the caller) and produces a JSON-ready Ruby
    # Hash, keyed by ivar name, applying the SAME prop-exposure policy as the
    # Flight serializer ({Ruact::Flight::Serializer#serialize_unknown}):
    #
    #   - {Ruact::Serializable} values expose ONLY their `ruact_props` (secrets
    #     never leak), recursing into nested Serializables / collections.
    #   - Under `strict_serialization`, a non-Serializable domain object raises
    #     {Ruact::SerializationError} (no accidental full-record dump).
    #   - Otherwise a vetted `as_json` fallback applies (guards against
    #     `as_json` returning self / raising).
    #
    # Unlike the Flight serializer this produces PLAIN JSON-ready values (Hash /
    # Array / scalar) — `render json:` does the final encoding, so JSON
    # primitives (incl. Time/Date) pass through untouched rather than being
    # Flight-encoded.
    #
    # Pure — no Rails / request / `Ruact.config` reads. The caller resolves the
    # exposed-ivar set and the `strict` flag (mirroring the {ErrorPayload}
    # caller/builder split, NFR26 / AC8).
    module BucketTwoPayload
      # JSON scalar + date/time primitives pass through untouched (Rails'
      # `render json:` renders them — e.g. Time → ISO8601). They are NOT
      # subject to the strict prop-exposure policy, matching the Flight
      # serializer's primitive handling.
      PRIMITIVES = [NilClass, TrueClass, FalseClass, Numeric, String, Symbol, Time, Date, DateTime].freeze
      private_constant :PRIMITIVES

      class << self
        # @param assigns [Hash] exposed-ivar name (String, no `@`) => value
        # @param strict [Boolean] the resolved `strict_serialization` mode
        # @return [Hash{String=>Object}] JSON-ready hash keyed by ivar name
        # @raise [Ruact::SerializationError] per the strict policy
        def build(assigns, strict:)
          assigns.to_h { |name, value| [name.to_s, serialize(value, strict)] }
        end

        # Story 9.4 (D6) — the per-value branch of the policy, extracted so the
        # query dispatch controller serializes a method's single RETURN VALUE
        # (Array / Hash / scalar / Serializable / nil) through the exact rules
        # {.build} applies to each exposed ivar. One policy, two callers.
        #
        # @param value [Object] the query method's return value
        # @param strict [Boolean] the resolved `strict_serialization` mode
        # @return [Object] JSON-ready value (`nil` stays `nil` → JSON `null`)
        # @raise [Ruact::SerializationError] per the strict policy
        def serialize_value(value, strict:)
          serialize(value, strict)
        end

        private

        def serialize(value, strict)
          case value
          when *PRIMITIVES         then value
          when Hash                then value.to_h { |k, v| [k.to_s, serialize(v, strict)] }
          when Array               then value.map { |v| serialize(v, strict) }
          when Ruact::Serializable then serialize(value.ruact_serialize, strict)
          else serialize_object(value, strict)
          end
        end

        # Non-Serializable, non-primitive object: mirror
        # Flight::Serializer#serialize_unknown's strict/as_json policy.
        def serialize_object(value, strict)
          unless value.respond_to?(:as_json)
            raise Ruact::SerializationError,
                  "Cannot serialize #{value.class.name} — include Ruact::Serializable"
          end

          if strict
            raise Ruact::SerializationError,
                  "Cannot serialize #{value.class.name} — " \
                  "include Ruact::Serializable or set strict_serialization: false"
          end

          serialize(as_json_value(value), strict)
        end

        def as_json_value(value)
          data =
            begin
              value.as_json
            rescue StandardError => e
              raise Ruact::SerializationError,
                    "#{value.class.name}#as_json raised #{e.class}: #{e.message}"
            end

          if data.equal?(value)
            raise Ruact::SerializationError,
                  "#{value.class.name}#as_json returned self — would cause infinite recursion. " \
                  "Include Ruact::Serializable and declare ruact_props instead"
          end

          data
        end
      end
    end
  end
end
