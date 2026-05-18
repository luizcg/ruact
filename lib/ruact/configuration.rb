# frozen_string_literal: true

module Ruact
  # Holds gem-wide configuration. Instantiated once via Ruact.config.
  # Configure via `Ruact.configure { |c| c.attr = value }` in an initializer.
  #
  # Frozen after `Ruact.configure` returns (Story 7.3) — direct post-boot
  # mutation (`Ruact.config.attr = value` outside the block) raises
  # `Ruact::ConfigurationError` with the offending attribute, the caller's
  # file:line, and the suggested fix. Re-calling `Ruact.configure` after boot
  # replaces the configuration atomically and emits a `[ruact]` warning.
  class Configuration
    # The set of public attributes; new attributes added here automatically
    # inherit the freeze contract via the `define_method` writer below.
    ATTRIBUTES = %i[manifest_path strict_serialization suspense_timeout vite_dev_server current_user_resolver].freeze

    # @!attribute [r] manifest_path
    #   @return [String, nil] Path to react-client-manifest.json.
    #     Defaults to Rails.root.join("public/react-client-manifest.json") when nil.
    #
    # @!attribute [r] strict_serialization
    #   @return [Boolean] When true, objects without explicit ruact_props declaration
    #     raise Ruact::SerializationError. Defaults to false in development, true in production.
    #
    # @!attribute [r] suspense_timeout
    #   @return [Float] Seconds before a deferred Suspense chunk times out. Default: 5.0.
    #
    # @!attribute [r] vite_dev_server
    #   @return [String] Base URL of the Vite dev server. Default: "http://localhost:5173".
    #
    # @!attribute [r] current_user_resolver
    #   @return [Proc, nil] Story 8.3 — Lambda invoked by the standalone
    #     server-action dispatcher when a block reads `current_user`. Receives
    #     `request.env` (Hash) and returns the authenticated user (or nil).
    #     Memoized per-dispatch; left nil by default so apps that don't use
    #     standalone actions never get a phantom `current_user` resolver.
    #   @example Devise
    #     Ruact.configure { |c| c.current_user_resolver = ->(env) { env['warden']&.user } }
    #   @example Hand-rolled session
    #     Ruact.configure { |c| c.current_user_resolver = ->(env) { User.find_by(id: env['rack.session'][:user_id]) } }
    ATTRIBUTES.each do |attr|
      attr_reader attr

      define_method("#{attr}=") do |value|
        if frozen?
          location = caller_locations(1, 1).first
          raise Ruact::ConfigurationError, build_error_message(attr, location)
        end
        instance_variable_set("@#{attr}", value)
      end
    end

    # Build a fresh Configuration. When +template+ is given, dup every public
    # attribute from it so the draft is mutable — used by `Ruact.configure` for
    # atomic-replacement cloning. The dup is required because the template is
    # always a published (frozen) Configuration with deep-frozen attribute
    # values, and AC1 requires the DSL inside the configure block to behave
    # identically regardless of whether this is the first call or a later one
    # (including idiomatic in-place mutation of inherited values).
    #
    # `dup` is safe for every supported attribute type: Strings produce an
    # unfrozen copy; nil/true/false/Numerics/Symbols dup to themselves (they
    # are inherently immutable, so the dup is a no-op).
    #
    # @param template [Ruact::Configuration, nil] optional source to clone from
    def initialize(template: nil)
      if template
        ATTRIBUTES.each do |attr|
          value = template.public_send(attr)
          # Procs are immutable from the outside (Story 8.3 — current_user_resolver).
          # Duping creates a different Proc instance, breaking identity comparisons
          # across re-configurations. Procs are inherently re-entrant safe (no
          # mutable internal state surface) so the dup is unnecessary; the freeze
          # at seal! time is enough.
          cloned = value.is_a?(Proc) ? value : value.dup
          instance_variable_set("@#{attr}", cloned)
        end
      else
        @manifest_path        = nil
        @strict_serialization = begin
          Rails.env.production?
        rescue StandardError
          false
        end
        @suspense_timeout     = 5.0
        @vite_dev_server      = "http://localhost:5173"
        @current_user_resolver = nil
      end
    end

    private

    # Internal — called by `Ruact.configure` and `Ruact.config` (via
    # `__send__(:seal!)`) immediately before publication. Deep-freezes every
    # attribute value so the shallow `Object#freeze` on the Configuration
    # cannot be bypassed by in-place mutation of an attribute value (e.g.
    # `Ruact.config.manifest_path.replace`) after publication. Returns self
    # (frozen).
    #
    # Values remain mutable inside the `Ruact.configure` block (AC1: the DSL
    # inside the block is unchanged; the freeze happens after the block
    # returns, not before). Only on `seal!` are values deep-frozen.
    #
    # Defined as `private` so it does not appear on the public API surface
    # of `Ruact::Configuration` (AC1/AC7/AC9: public API surface unchanged).
    # External callers reaching into `Ruact.config.seal!` get a NoMethodError.
    #
    # @api private
    # @return [Ruact::Configuration] self, frozen
    def seal!
      ATTRIBUTES.each do |attr|
        value = public_send(attr)
        next if value.nil? || value.frozen?

        # Story 8.3 review — Procs CAN be frozen (`.freeze` flips the frozen
        # flag; no operational effect on `.call`). Freezing in place preserves
        # object identity (vital for code that compares the resolver across
        # re-configurations) AND keeps the deep-freeze contract honest —
        # `Ruact.config.current_user_resolver.freeze` later would otherwise
        # silently no-op an already-frozen reference, but a caller probing
        # `frozen?` would see the right answer.
        if value.is_a?(Proc)
          value.freeze
        else
          instance_variable_set("@#{attr}", value.dup.freeze)
        end
      end
      freeze
    end

    def build_error_message(attr, location)
      <<~MSG.strip
        ruact: cannot mutate Ruact::Configuration##{attr} after initialization.
          Attempted at: #{location.path}:#{location.lineno}
          Wrap the change in Ruact.configure { |c| c.#{attr} = ... } in config/initializers/ruact.rb and restart the process.
          Why: Ruact::Configuration is frozen after initialization (Story 7.3) so that runtime config drift cannot cause environment-dependent behavior.
      MSG
    end
  end
end
