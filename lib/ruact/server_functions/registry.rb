# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # In-memory storage for server-function entries. One instance backs
    # `Ruact.action_registry`; another backs `Ruact.query_registry` — kept
    # separate so the JSON snapshot can emit a `kind` field per entry without
    # the call sites having to thread an extra parameter through. Cross-registry
    # JS-identifier collisions are detected by {Ruact::ServerFunctions::Snapshot}
    # at snapshot time (a single registry only sees its own entries).
    #
    # Thread-safety: not thread-safe by design. Registration happens at
    # controller-class load time (`config.to_prepare` in dev, eager-load in
    # production), single-threaded. Reads from {#entries} return a frozen
    # snapshot of the internal hash so concurrent readers cannot observe a
    # partial registration.
    class Registry
      # The only kinds the codegen knows how to emit. Story 8.1 owns `:action`,
      # Story 9.1 owns `:query`. Any other value is rejected at registration
      # time — silent acceptance would otherwise let an unknown kind fall
      # through and be emitted as an action signature.
      ALLOWED_KINDS = %i[action query].freeze

      def initialize
        @entries = {}
      end

      # Adds +symbol+ to the registry.
      #
      # @param symbol [Symbol] the Ruby identifier (snake_case).
      # @param kind [Symbol] `:action` or `:query`. Other values raise.
      # @param controller [Class, nil] the controller class registering the
      #   function. Used in collision-error messages.
      # @yield the implementation body; stored verbatim for Story 8.1 / 9.1 to
      #   invoke. May be nil for Story 8.0a's bootstrap (registries are empty
      #   until 8.1 and 9.1 land).
      # @return [Ruact::ServerFunctions::RegistryEntry] the entry just inserted.
      # @raise [Ruact::ConfigurationError] when +symbol+ fails the naming-bridge
      #   rule, when +kind+ is not in {ALLOWED_KINDS}, or when a different Ruby
      #   symbol already maps to the same JS identifier in THIS registry. Cross-
      #   registry collisions (one action + one query sharing a JS identifier)
      #   are detected later by {Ruact::ServerFunctions::Snapshot.functions_payload}.
      def register(symbol, kind:, controller: nil, &block)
        validate_kind!(symbol, kind, controller)
        js_identifier = translate_symbol(symbol, controller)
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

      def validate_kind!(symbol, kind, controller)
        return if ALLOWED_KINDS.include?(kind)

        raise Ruact::ConfigurationError,
              "invalid server-function symbol :#{symbol} in #{describe_controller(controller)}: " \
              "kind #{kind.inspect} is not one of #{ALLOWED_KINDS.inspect}"
      end

      # Wraps the NameBridge call to attach controller context to the raised
      # error (the AC7 "invalid server-function symbol :SYMBOL in CONTROLLER"
      # shape). NameBridge itself is controller-agnostic; the wrap lives at the
      # registry boundary because that is where controller context exists.
      def translate_symbol(symbol, controller)
        NameBridge.to_js_identifier(symbol)
      rescue Ruact::ConfigurationError => e
        raise Ruact::ConfigurationError,
              "invalid server-function symbol :#{symbol} in #{describe_controller(controller)} — #{e.message}"
      end

      def detect_collision!(symbol, js_identifier, controller)
        # Re-run-3 (2026-05-15) — TWO failure shapes:
        #
        # (a) Different Ruby symbols, same JS identifier (`:foo_bar` and
        #     `:fooBar` both → "fooBar"). Filtered by `js_identifier ==`.
        # (b) Same Ruby symbol declared on TWO different controllers
        #     (e.g., `ruact_action :create_post` in both `PostsController`
        #     AND `AdminPostsController`). Pre-batch this silently
        #     overwrote `@entries[symbol]` with the last-loaded one, so
        #     dispatch routed to whichever controller Zeitwerk happened
        #     to load last — non-deterministic in dev, surprise breakage
        #     when refactoring. Detect by checking the existing entry's
        #     `controller` against the one trying to register.
        existing = @entries[symbol]
        if existing && existing.controller != controller
          raise Ruact::ConfigurationError,
                "server-function naming collision: " \
                ":#{symbol} is declared in BOTH " \
                "#{describe_controller(existing.controller)} and " \
                "#{describe_controller(controller)}. Each `ruact_action` " \
                "symbol must be unique across the whole registry — pick a " \
                "more specific name (e.g. :admin_create_post) on one side."
        end

        collision = @entries.values.find do |e|
          e.js_identifier == js_identifier && e.ruby_symbol != symbol
        end
        return unless collision

        raise Ruact::ConfigurationError,
              "server-function naming collision: " \
              ":#{symbol} (in #{describe_controller(controller)}) and " \
              ":#{collision.ruby_symbol} (in #{describe_controller(collision.controller)}) " \
              "both map to JS identifier \"#{js_identifier}\""
      end

      def describe_controller(controller)
        return "unknown controller" if controller.nil?

        controller.respond_to?(:name) && controller.name ? controller.name : controller.inspect
      end
    end
  end
end
