# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # In-memory storage for server-function entries. One instance backs
    # `Ruact.action_registry`; another backs `Ruact.query_registry` — kept
    # separate so the JSON snapshot can emit a `kind` field per entry without
    # the call sites having to thread an extra parameter through.
    #
    # Thread-safety: not thread-safe by design. Registration happens at
    # controller-class load time (`config.to_prepare` in dev, eager-load in
    # production), single-threaded. Reads from {#entries} return a frozen
    # snapshot of the internal hash so concurrent readers cannot observe a
    # partial registration.
    class Registry
      def initialize
        @entries = {}
      end

      # Adds +symbol+ to the registry.
      #
      # @param symbol [Symbol] the Ruby identifier (snake_case).
      # @param kind [Symbol] `:action` or `:query` — informational, used by the
      #   snapshot and downstream tooling.
      # @param controller [Class, nil] the controller class registering the
      #   function. Used in collision-error messages.
      # @yield the implementation body; stored verbatim for Story 8.1 / 9.1 to
      #   invoke. May be nil for Story 8.0a's bootstrap (registries are empty
      #   until 8.1 and 9.1 land).
      # @return [Ruact::ServerFunctions::RegistryEntry] the entry just inserted.
      # @raise [Ruact::ConfigurationError] when +symbol+ fails the naming-bridge
      #   rule or when a different Ruby symbol already maps to the same JS
      #   identifier.
      def register(symbol, kind:, controller: nil, &block)
        js_identifier = NameBridge.to_js_identifier(symbol)
        detect_collision!(symbol, js_identifier, controller)

        entry = RegistryEntry.new(
          ruby_symbol: symbol,
          js_identifier: js_identifier,
          kind: kind,
          controller: controller,
          block: block
        )
        @entries[symbol] = entry
        entry
      end

      # @return [Hash{Symbol => Ruact::ServerFunctions::RegistryEntry}] frozen
      #   snapshot of the current entries, ordered by insertion.
      def entries
        @entries.dup.freeze
      end

      # Wipes the registry. Used by `config.to_prepare` (between dev reloads) and
      # by tests that need a clean slate.
      #
      # @return [self]
      def clear!
        @entries.clear
        self
      end

      # @return [Integer] number of registered entries.
      def size
        @entries.size
      end

      # @return [Boolean] whether the registry has no entries.
      def empty?
        @entries.empty?
      end

      private

      def detect_collision!(symbol, js_identifier, controller)
        existing = @entries.values.find do |e|
          e.js_identifier == js_identifier && e.ruby_symbol != symbol
        end
        return unless existing

        raise Ruact::ConfigurationError,
              "ruact server-function naming collision: " \
              ":#{symbol} (in #{describe_controller(controller)}) and " \
              ":#{existing.ruby_symbol} (in #{describe_controller(existing.controller)}) " \
              "both map to JS identifier \"#{js_identifier}\""
      end

      def describe_controller(controller)
        return "unknown controller" if controller.nil?

        controller.respond_to?(:name) && controller.name ? controller.name : controller.inspect
      end
    end
  end
end
