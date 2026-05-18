# frozen_string_literal: true

module Ruact
  # Story 8.3 — host module for STANDALONE server actions. The Ruby
  # equivalent of React's `"use server"` directive: a module under
  # `app/server_actions/` that `extend`s {Ruact::ServerAction} and declares
  # one action body per file with the `ruact_action` macro.
  #
  #   # app/server_actions/create_post.rb
  #   module CreatePost
  #     extend Ruact::ServerAction
  #
  #     ruact_action :create_post do |params|
  #       Post.create!(title: params[:title], body: params[:body])
  #     end
  #   end
  #
  # The React side cannot tell standalone-hosted actions apart from
  # controller-hosted ones — both export under the same accessor at
  # `app/javascript/.ruact/server-functions.ts` (Story 8.0a codegen).
  #
  # Differences from {Ruact::Controller#ruact_action} (the controller-hosted
  # path from Story 8.1):
  #
  #   - NO instance method is defined on the host module. There is no
  #     `host.public_send(action_name)` call shape — the dispatcher
  #     ({Ruact::ServerFunctions::EndpointController}) detects the standalone
  #     host shape and routes through {Ruact::ServerFunctions::StandaloneDispatcher}
  #     instead of `host_class.dispatch`. Standalone modules are reachable
  #     ONLY through the gem's `POST /__ruact/fn/:name` endpoint; there is
  #     no public Ruby surface to invoke them, by design.
  #   - NO controller `before_action` chain runs. The dev opts out of the
  #     controller-DSL ergonomic by picking the standalone path; the
  #     trade-off is no implicit auth/scoping. The dev calls `current_user`
  #     (resolved via {Ruact::Configuration#current_user_resolver}) and
  #     Pundit / ActionPolicy directly inside the block when needed.
  #   - NO `method_added` hook, NO `Thread.current[:__ruact_dispatching]`
  #     sentinel. The standalone path has no routing surface that could
  #     reach the action body outside of the gem-managed endpoint, so the
  #     controller-only security guards are unnecessary (and would be
  #     misleading — the block is stored in the registry, not on the
  #     module as an instance method).
  #
  # Shared with {Ruact::Controller#ruact_action}:
  #
  #   - {Ruact::ServerFunctions::Registry} via `Ruact.action_registry`.
  #     Symbols declared by standalone modules and by controller hosts live
  #     in the same registry instance; the existing collision detector
  #     ({Ruact::ServerFunctions::Registry#detect_collision!}) catches
  #     same-symbol-different-host collisions across both host shapes.
  #   - The naming-bridge rule ({Ruact::ServerFunctions::NameBridge}) and
  #     reserved-identifier sets (`RESERVED_JS_IDENTIFIERS`,
  #     `RESERVED_BY_RUACT`).
  #   - The block-parameter shape guard (one positional argument, no
  #     required keyword arguments) — same regex as Story 8.1 Re-run-5.
  module ServerAction
    # @param symbol [Symbol] the action name; same naming-bridge rule as
    #   {Ruact::Controller#ruact_action}.
    # @yield [params] the block runs via `instance_exec` on a fresh
    #   {Ruact::ServerFunctions::StandaloneContext} at dispatch time.
    # @return [Ruact::ServerFunctions::RegistryEntry] the entry just registered.
    # @raise [ArgumentError] when +symbol+ is not a Symbol, the block is
    #   missing, or the block's parameter shape is rejected.
    # @raise [Ruact::ConfigurationError] when the symbol fails the
    #   naming-bridge rule or collides with another `ruact_action` in the
    #   registry (mixed-host collisions are caught here too — see AC4).
    def ruact_action(symbol, &block)
      # Story 8.3 review R4 — reject Class hosts loudly. `extend Ruact::ServerAction`
      # on a Class would work at extend time (Class < Module), but the
      # endpoint dispatcher's `standalone_host?` predicate returns false for
      # Class hosts (it requires Module-NOT-Class), and the controller-DSL
      # branch would then try `host_class.dispatch(...)` against a class
      # that has NO Rails dispatch surface — crashing at request time.
      # Catch this at declaration time so the failure is visible at boot.
      if is_a?(Class)
        raise Ruact::ConfigurationError,
              "Ruact::ServerAction is intended for standalone HOST MODULES under " \
              "`app/server_actions/`. You extended it onto #{name || self} which " \
              "is a Class — that's a controller-shape host. For controller-hosted " \
              "actions use `include Ruact::Controller` and declare `ruact_action` " \
              "inside the controller class body; for standalone actions declare a " \
              "`module Foo; extend Ruact::ServerAction; ...; end` instead."
      end

      unless symbol.is_a?(Symbol)
        raise ArgumentError,
              "ruact_action requires a Symbol argument, got " \
              "#{symbol.inspect} (#{symbol.class}). Use " \
              "`ruact_action :#{symbol}` not `ruact_action #{symbol.inspect}`."
      end

      unless block
        raise ArgumentError,
              "ruact_action :#{symbol} (standalone) requires a block — declare the " \
              "implementation with `ruact_action :#{symbol} do |params| ... end`"
      end

      # Mirror the block-parameter shape guard from Story 8.1 Re-run-5
      # (controller.rb:125-137). The standalone dispatcher invokes the
      # block with one positional argument (the params shadow); blocks
      # with wrong arity / required kwargs would crash at dispatch time.
      req_count    = block.parameters.count { |kind, _| kind == :req }
      opt_count    = block.parameters.count { |kind, _| kind == :opt }
      rest_count   = block.parameters.count { |kind, _| kind == :rest }
      named_positional = req_count + opt_count
      positional_total = named_positional + rest_count
      has_required_kwarg = block.parameters.any? { |kind, _| kind == :keyreq }
      if positional_total.zero? || named_positional > 1 || has_required_kwarg
        raise ArgumentError,
              "ruact_action :#{symbol} (standalone) block must accept exactly one " \
              "positional parameter and no required keyword arguments " \
              "(got parameters=#{block.parameters.inspect}). Use " \
              "`ruact_action :#{symbol} do |params| ... end`."
      end

      # NOTE: no `FRAMEWORK_RESERVED_METHODS` check — standalone modules
      # have no ActionController surface to clobber. NameBridge +
      # RESERVED_JS_IDENTIFIERS + RESERVED_BY_RUACT still fire via the
      # registry's `register` path below.
      #
      # NOTE: no `own_methods` / inherited-helper guard — there is no
      # `define_method` step that could shadow anything; the block lives
      # in the registry, not on the module.
      #
      # NOTE: no `method_added` hook — standalone modules don't define
      # instance methods at all, so a same-name `def` cannot shadow
      # anything (Pitfall #2 in the story spec).
      Ruact.action_registry.register(symbol, kind: :action, controller: self, &block)
    end
  end
end
