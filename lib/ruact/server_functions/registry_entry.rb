# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Immutable record describing a single registered server function. Stored by
    # {Ruact::ServerFunctions::Registry}; serialized into the JSON snapshot by
    # {Ruact::ServerFunctions::Snapshot}.
    #
    # @!attribute [r] ruby_symbol
    #   @return [Symbol] the symbol the controller registered (e.g. `:create_post`).
    # @!attribute [r] js_identifier
    #   @return [String] result of {Ruact::ServerFunctions::NameBridge.to_js_identifier}
    #     — cached at registration time so the snapshot writer never re-derives it.
    # @!attribute [r] kind
    #   @return [Symbol] `:action` or `:query`. Informational at codegen time
    #     (Story 8.0 decision 2A-i: both kinds POST through the same accessor).
    # @!attribute [r] controller
    #   @return [Class, nil] the controller class that registered the function;
    #     used for collision-error messages and downstream tooling. Nil is allowed
    #     for tests / Rails-console registrations.
    # @!attribute [r] block
    #   @return [Proc, nil] the implementation block supplied by the controller
    #     macro. Story 8.0a stores it untouched; Stories 8.1 / 9.1 invoke it.
    RegistryEntry = Data.define(:ruby_symbol, :js_identifier, :kind, :controller, :block)
  end
end
