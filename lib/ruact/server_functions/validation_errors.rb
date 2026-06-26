# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 13.3 (FR98) — pure normalizer for the Inertia-style validation
    # `errors` round-trip. Turns whatever a host action has on hand after a save
    # attempt — an ActiveModel-ish record (responds to `#errors`), a raw
    # `ActiveModel::Errors`, or a pre-shaped Hash — into ONE canonical wire
    # shape — e.g. `"title" => ["Title can't be blank"]` and
    # `"base" => ["is invalid overall"]` collected into one
    # `Hash{String=>Array<String>}` — attribute names as strings (a
    # `base`-level error keys under `"base"`), values arrays of human-readable
    # **full messages**. A valid record (empty `#errors`) yields `{}`, never
    # `nil`/`undefined`, so a single client code path handles both success and
    # failure (the "always present" invariant of AC1).
    #
    # Pure: no `Rails` constant references at load, no `Ruact.config` / request
    # reads — duck-typing only (mirrors the caller/builder split of
    # {ErrorPayload} / {BucketTwoPayload}). The caller (`Ruact::Server#ruact_errors`)
    # owns the per-request collector and the bucket/flash wiring; this module
    # only answers "what is the canonical shape of this source?".
    module ValidationErrors
      class << self
        # Normalize a validation-error source into the canonical Hash shape.
        #
        # Accepts, in precedence order:
        #   - `nil` → `{}`
        #   - a Hash already shaped `{attr => [msgs]}` → keys coerced to String,
        #     scalar values wrapped in a one-element Array, every message
        #     coerced to String; idempotent on already-canonical input.
        #   - an object responding to `#group_by_attribute` (a raw
        #     `ActiveModel::Errors`) → grouped into `{attr => [full_message]}`.
        #   - an object responding to `#errors` (an ActiveModel-ish record) →
        #     normalized from its `#errors`.
        #   - anything else → `{}` (no errors discoverable).
        #
        # @param source [nil, Hash, #group_by_attribute, #errors] the error source
        # @return [Hash{String=>Array<String>}] the canonical, always-present shape
        def normalize(source)
          return {} if source.nil?
          return normalize_hash(source) if source.is_a?(Hash)
          return group_errors(source) if source.respond_to?(:group_by_attribute)
          return normalize(source.errors) if source.respond_to?(:errors)

          {}
        end

        private

        # A raw `ActiveModel::Errors`: group its `Error` objects by attribute and
        # render each as a full message (`"Title can't be blank"`).
        def group_errors(errors)
          errors.group_by_attribute.each_with_object({}) do |(attribute, attribute_errors), acc|
            acc[attribute.to_s] = attribute_errors.map(&:full_message)
          end
        end

        # A pre-shaped Hash: stringify keys, wrap scalar values in a one-element
        # array, stringify every message. `Array()` makes a `nil` value collapse
        # to `[]` and is a no-op on an existing Array (idempotent on canonical
        # input).
        def normalize_hash(hash)
          hash.each_with_object({}) do |(key, value), acc|
            acc[key.to_s] = Array(value).map(&:to_s)
          end
        end
      end
    end
  end
end
