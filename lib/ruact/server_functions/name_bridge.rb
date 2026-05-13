# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Translates a Ruby symbol into the JS identifier exported from
    # `app/javascript/.ruact/server-functions.ts`. The bridge is Ruby-side only;
    # the Vite plugin reads the already-translated identifier from the JSON
    # snapshot and emits it verbatim (Story 8.0a design decision: one source of
    # truth for naming).
    #
    # Rules (locked by Story 8.0 ADR):
    # - Symbol must match `/\A[a-z_][a-z0-9_]*\z/`; otherwise raises
    #   {Ruact::ConfigurationError} at controller-class load time.
    # - A single leading underscore is preserved (e.g. `:_internal_dump` →
    #   `"_internalDump"`).
    # - Runs of underscores collapse and uppercase the following alphanumeric
    #   (e.g. `:foo__bar` → `"fooBar"`).
    #
    # @see https://docs/internal/decisions/server-functions-api.md "Naming bridge"
    module NameBridge
      VALID_SYMBOL = /\A[a-z_][a-z0-9_]*\z/

      class << self
        # @param symbol [Symbol, String] the Ruby identifier registered via
        #   `ruact_action` / `ruact_query` (Phase 2 stories 8.1 and 9.1).
        # @return [String] the corresponding JS identifier.
        # @raise [Ruact::ConfigurationError] when +symbol+ does not match the
        #   allowed shape — caught at controller load time so misnamed routes
        #   never reach production.
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

          leading = str.start_with?("_") ? "_" : ""
          body    = str.sub(/\A_+/, "")
          leading + body.gsub(/_+([a-z0-9])/) { Regexp.last_match(1).upcase }
        end
      end
    end
  end
end
