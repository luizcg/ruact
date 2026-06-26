# frozen_string_literal: true

require "json"

module Ruact
  module ServerFunctions
    module Codegen
      module V2
        # Story 13.4 (FR99) — builds the TYPED query accessor `params` signature
        # from the per-kwarg metadata {QuerySource} derives, and validates that
        # metadata as a trust boundary. Extracted from {V2} for the same reason
        # {V2} was extracted from {Codegen}: keep each singleton class within its
        # size budget. Constants ({QUERY_SIGNATURE}, {QUERY_PARAMS_SIGNATURE},
        # {QUERY_PARAM_VALUE_TYPE}, {VALID_JS_IDENTIFIER}, {LINE_TERMINATORS}) are
        # reached from {Codegen} via lexical scope.
        #
        # MUST stay byte-identical to the JS-side `querySignatureV2` /
        # `validateQueryParams` in
        # `gem/vendor/javascript/vite-plugin-ruact/server-functions-codegen.mjs`.
        module QueryParams
          class << self
            # Picks the query accessor's `params` signature.
            #
            # When +params+ is an Array (the Story 13.4 structured metadata),
            # build a typed object literal — one property per declared keyword,
            # required/optional exact, value type the FR88 wire union (AC1).
            # Empty params + no `**keyrest` → the bare {QUERY_SIGNATURE}
            # (byte-identical to a no-kwargs query). A `**keyrest` keeps the open
            # `Record<string, unknown>` (intersected with any named keys) so a
            # legitimate dynamic key is never narrowed away (fail open).
            #
            # Falls back to the pre-13.4 +accepts_params+ boolean when no
            # +params+ metadata is present (an older or hand-written snapshot)
            # so no consumer breaks.
            #
            # @param params [Array<Hash>, nil] per-kwarg `{ "name", "required" }`.
            # @param params_rest [Boolean, nil] whether a `**keyrest` is declared.
            # @param accepts_params [Boolean, nil] the back-compat fallback flag.
            # @return [String] the TS signature.
            def signature(params:, params_rest:, accepts_params:)
              return fallback(accepts_params) unless params.is_a?(Array)

              rest = params_rest ? true : false
              return QUERY_SIGNATURE if params.empty? && !rest

              build(params, rest)
            end

            # Validates the structured `params` metadata. Reject a malformed or
            # corrupted snapshot loudly rather than emit broken — or silently
            # over-widened — TS. Absent `params`/`params_rest` is valid (the
            # {signature} fallback handles it).
            #
            # @param js_id [String]
            # @param params [Array<Hash>, nil]
            # @param params_rest [Object, nil] expected Boolean or nil; a
            #   non-Boolean truthy value would otherwise silently flip a query to
            #   the open `& Record<string, unknown>` shape (Story 13.4 review R1).
            # @raise [Ruact::ConfigurationError]
            def validate!(js_id, params, params_rest = nil)
              validate_rest!(js_id, params_rest)
              return if params.nil?

              unless params.is_a?(Array)
                raise Ruact::ConfigurationError,
                      "ruact server-function codegen: v2 query entry #{js_id.inspect} has invalid " \
                      "params #{params.inspect} (must be an Array of { name, required } objects)."
              end
              params.each { |param| validate_entry!(js_id, param) }
            end

            private

            def validate_rest!(js_id, params_rest)
              return if params_rest.nil? || params_rest == true || params_rest == false

              raise Ruact::ConfigurationError,
                    "ruact server-function codegen: v2 query entry #{js_id.inspect} has a non-Boolean " \
                    "params_rest #{params_rest.inspect}; snapshot JSON is corrupted."
            end

            def fallback(accepts_params)
              accepts_params ? QUERY_PARAMS_SIGNATURE : QUERY_SIGNATURE
            end

            # Builds `(params: { q: <UNION>; limit?: <UNION> }) => Promise<unknown>`
            # in declaration order. A `**keyrest`-only query (no named keys)
            # reuses the open {QUERY_PARAMS_SIGNATURE}; with named keys present
            # the rest is an intersection so the named keys still autocomplete.
            def build(params, rest)
              props = params.map do |param|
                name = param["name"] || param[:name]
                required = param.key?("required") ? param["required"] : param[:required]
                optional = required ? "" : "?"
                "#{format_key(name)}#{optional}: #{QUERY_PARAM_VALUE_TYPE}"
              end

              return QUERY_PARAMS_SIGNATURE if props.empty? # keyrest-only

              object = "{ #{props.join('; ')} }"
              object += " & Record<string, unknown>" if rest
              "(params: #{object}) => Promise<unknown>"
            end

            # Kwarg names are Ruby symbols → almost always valid bare TS keys;
            # quote (via JSON) any that are not so a corrupted snapshot cannot
            # break out of the object literal. Mirrors the JS `formatParamKey`.
            def format_key(name)
              name.to_s.match?(VALID_JS_IDENTIFIER) ? name.to_s : JSON.dump(name.to_s)
            end

            def validate_entry!(js_id, param)
              unless param.is_a?(Hash)
                raise Ruact::ConfigurationError,
                      "ruact server-function codegen: v2 query entry #{js_id.inspect} has a params " \
                      "element that is not an object: #{param.inspect}; snapshot JSON is corrupted."
              end

              name = param["name"] || param[:name]
              unless name.is_a?(String) && !name.empty? && !name.match?(LINE_TERMINATORS)
                raise Ruact::ConfigurationError,
                      "ruact server-function codegen: v2 query entry #{js_id.inspect} has a params " \
                      "name #{name.inspect} that is not a non-empty single-line String; snapshot JSON is corrupted."
              end

              # Presence-aware (a plain `||` would mis-read a legitimate
              # `required: false` as the absent key).
              required = param.key?("required") ? param["required"] : param[:required]
              return if [true, false].include?(required)

              raise Ruact::ConfigurationError,
                    "ruact server-function codegen: v2 query entry #{js_id.inspect} params name " \
                    "#{name.inspect} has a non-Boolean `required` #{required.inspect}; snapshot JSON is corrupted."
            end
          end
        end
      end
    end
  end
end
