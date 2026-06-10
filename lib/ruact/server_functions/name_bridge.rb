# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Translates a Ruby symbol into the JS identifier exported from
    # `app/javascript/.ruact/server-functions.ts`. The bridge is Ruby-side only;
    # the Vite plugin reads the already-translated identifier from the JSON
    # snapshot and emits it verbatim (Story 8.0a design decision: one source of
    # truth for naming).
    #
    # Rules (locked by Story 8.0 ADR + 2026-05-13 review-patch tightening):
    # - Symbol must match `/\A[a-z_][a-z0-9_]*\z/`; otherwise raises
    #   {Ruact::ConfigurationError} at controller-class load time.
    # - A single leading underscore is preserved (e.g. `:_internal_dump` →
    #   `"_internalDump"`).
    # - Runs of underscores collapse and uppercase the following alphanumeric
    #   (e.g. `:foo__bar` → `"fooBar"`).
    # - The source symbol cannot be made of underscores alone (`:_`, `:__`, …) —
    #   would otherwise emit `"_"`, which carries no semantic content and
    #   collides with the common "ignored value" lint convention.
    # - The translated JS identifier cannot match a JavaScript reserved word
    #   or future-reserved word (ES2020+ list plus the module-top-level
    #   `await` / `async`). `:class` → `"class"` would compile under Babel
    #   loose-mode but break under `tsc --noEmit` and most ESLint configs.
    #
    # @see docs/internal/decisions/server-functions-api.md "Naming bridge"
    module NameBridge
      VALID_SYMBOL = /\A[a-z_][a-z0-9_]*\z/

      UNDERSCORE_ONLY = /\A_+\z/

      # ES2020+ reserved + strict-mode reserved + contextually-reserved at
      # module top level + strict-mode invalid binding names. The codegen emits
      # in a module context (the generated `app/javascript/.ruact/server-functions.ts`
      # is `"type": "module"`, so all code runs in strict mode), so `await`,
      # `eval`, and `arguments` are all reserved as identifier names.
      # Keep this list sorted; matches the MDN reference plus the contextual
      # additions and the strict-mode `eval`/`arguments` ban from the
      # 2026-05-13 Re-run review patch.
      RESERVED_JS_IDENTIFIERS = %w[
        arguments async await break case catch class const continue
        debugger default delete do else enum eval export extends false
        finally for function if implements import in instanceof interface
        let new null package private protected public return static super
        switch this throw true try typeof var void while with yield
      ].to_set.freeze

      # Story 8.2 (2026-05-17 review patches R2 + R12) — names already
      # bound at the top of `app/javascript/.ruact/server-functions.ts`,
      # either by a helper re-export (`revalidate`, `useQuery`) or a runtime
      # import (`_makeRef`, `_makeServerFunction`, `_makeQuery`). A
      # `ruact_action :revalidate` / a query method `use_query` would emit a
      # clashing `export const` / duplicate export next to the existing
      # binding and crash the generated module at load time. The rule fires
      # at controller-class load / route-draw so the failure surfaces during
      # boot, not at first request.
      # Story 9.5 added `_makeQuery` (the v2 query import) and `useQuery` (the
      # query hook re-export) to this list.
      RESERVED_BY_RUACT = %w[
        _makeQuery
        _makeRef
        _makeServerFunction
        revalidate
        useQuery
      ].to_set.freeze

      class << self
        # @param symbol [Symbol, String] the Ruby identifier registered via
        #   `ruact_action` / `ruact_query` (Phase 2 stories 8.1 and 9.1).
        # @return [String] the corresponding JS identifier.
        # @raise [Ruact::ConfigurationError] when +symbol+ does not match the
        #   allowed shape, is all-underscores, or maps to a JS reserved word —
        #   caught at controller load time so misnamed routes never reach
        #   production.
        # @example
        #   Ruact::ServerFunctions::NameBridge.to_js_identifier(:create_post)
        #   # => "createPost"
        # @example leading underscore preserved
        #   Ruact::ServerFunctions::NameBridge.to_js_identifier(:_internal_dump)
        #   # => "_internalDump"
        def to_js_identifier(symbol)
          str = symbol.to_s

          unless str.match?(VALID_SYMBOL)
            raise Ruact::ConfigurationError,
                  "ruact_action / ruact_query symbol :#{symbol} must match /^[a-z_][a-z0-9_]*$/"
          end

          if str.match?(UNDERSCORE_ONLY)
            raise Ruact::ConfigurationError,
                  "ruact_action / ruact_query symbol :#{symbol} cannot be composed " \
                  "entirely of underscores (no semantic content)"
          end

          leading = str.start_with?("_") ? "_" : ""
          body    = str.sub(/\A_+/, "")
          js_id   = leading + body.gsub(/_+([a-z0-9])/) { Regexp.last_match(1).upcase }

          if RESERVED_JS_IDENTIFIERS.include?(js_id)
            raise Ruact::ConfigurationError,
                  "ruact_action / ruact_query symbol :#{symbol} maps to JS reserved " \
                  "word \"#{js_id}\" — pick a different Ruby symbol (e.g. :#{symbol}_action)"
          end

          if RESERVED_BY_RUACT.include?(js_id)
            raise Ruact::ConfigurationError,
                  "ruact_action / ruact_query symbol :#{symbol} maps to \"#{js_id}\", " \
                  "which is already exported by the ruact runtime from " \
                  "`@/.ruact/server-functions` and would emit a duplicate export. " \
                  "Pick a different Ruby symbol (e.g. :#{symbol}_action)."
          end

          js_id
        end
      end
    end
  end
end
