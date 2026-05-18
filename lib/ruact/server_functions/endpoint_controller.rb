# frozen_string_literal: true

require "action_controller"

module Ruact
  module ServerFunctions
    # Story 8.1 — the single gem-mounted Rails controller backing
    # `POST /__ruact/fn/:name`. It resolves the URL `:name` parameter to a
    # registered {Ruact::ServerFunctions::RegistryEntry}, allocates a fresh
    # instance of the entry's host controller class, and delegates dispatch
    # to that instance via Rails' standard `dispatch(action_name, request,
    # response)` plumbing.
    #
    # This indirection is what gives `ruact_action` blocks access to the host
    # controller's `current_user`, `session`, `before_action` chain, Pundit /
    # ActionPolicy authorization, and `rescue_from` handlers — the block runs
    # inside an honest controller instance, not in some gem-internal context.
    #
    # The `dispatch_action` action below is the ONLY public action on this
    # controller — there is no `:create`, `:update`, etc.; the host's actions
    # are reached indirectly via the wrapper method
    # `__ruact_action_<symbol>` that {Ruact::Controller#ruact_action} defines.
    class EndpointController < ActionController::Base
      # Story 8.1 AC8 — for controller-hosted actions the gem does NOT impose
      # its own CSRF protection: the host's `ApplicationController` is what
      # enforces `protect_from_forgery`; since those requests are dispatched
      # THROUGH a fresh host-controller instance below, the host's CSRF rules
      # apply. EndpointController itself only routes — never renders the
      # host's content directly.
      #
      # Story 8.3 — STANDALONE actions have no host controller, so there is
      # no host-side CSRF callback to delegate to. The endpoint enforces
      # CSRF for the standalone branch itself, gated by
      # `dispatching_standalone?` (resolved EARLY via prepend_before_action).
      # The controller-action branch keeps `skip_forgery_protection`-equivalent
      # behavior (the verify callback skips because the entry's host is a
      # Class, not a Module).
      skip_forgery_protection if respond_to?(:skip_forgery_protection)

      prepend_before_action :resolve_ruact_entry!

      # Story 8.3 — install a strategy + conditional callback so
      # `verify_authenticity_token` only fires on the standalone-dispatch
      # branch. `protect_from_forgery with: :exception, if: ...` is the
      # idiomatic Rails way to wire BOTH the forgery_protection_strategy
      # AND the before_action — using `before_action :verify_authenticity_token`
      # directly would crash because the strategy class would be nil. The
      # callback's `if:` proc resolves at request time after
      # `resolve_ruact_entry!` populates `@__ruact_entry`. Rails' own
      # `verified_request?` short-circuits when the host app sets
      # `config.action_controller.allow_forgery_protection = false` (API
      # mode), so the check is a no-op in that case — same observable
      # behavior as the controller-hosted branch under the same setting.
      protect_from_forgery with: :exception, if: :dispatching_standalone?

      # `POST /__ruact/fn/:name` (mounted by `Ruact::Railtie`).
      def dispatch_action
        entry = @__ruact_entry
        return render_unknown(@__ruact_name_sym) unless entry

        host = entry.controller
        if Ruact::ServerFunctions::EndpointController.standalone_host?(host)
          # Call StandaloneDispatcher WITHOUT passing the response so Rails'
          # `ImplicitRender` does not see an uncommitted response (writing
          # directly to `response.body =` would otherwise be silently
          # overwritten by the implicit-render 204). Apply the dispatcher's
          # Result directive via render/head, which Rails recognises as
          # rendered output.
          result = Ruact::ServerFunctions::StandaloneDispatcher.dispatch(entry, request)
          return apply_standalone_result(result)
        end

        unless host.is_a?(Class)
          return render(
            json: { error: "ruact action :#{@__ruact_name_sym} has an invalid host shape — " \
                           "expected a Controller class or a Module that extends Ruact::ServerAction" },
            status: :internal_server_error
          )
        end

        host_class = host

        # Re-run-2 (2026-05-14) — rebuild `request.path_parameters` so that
        # the host action sees `controller`/`action` keys describing ITSELF,
        # not the gem-endpoint route. Without this, `params[:controller]`
        # inside the host's action body returns
        # `"ruact/server_functions/endpoint"` and `params[:action]` returns
        # `"dispatch_action"` — which breaks `controller_name` /
        # `controller_path` / Pundit policy resolution / any code that reads
        # the routing identity. Restore after dispatch so the endpoint
        # response can be rendered with its own identity intact.
        # Re-run-4 (2026-05-15) — DROP `name: raw_name` from the swap.
        # The host action does not need the routing function name (it's
        # already inferable from `action_name`), and keeping it in
        # `path_parameters` made `params[:name]` inside the host action /
        # before_action chain return the route function name instead of
        # a legitimate submitted body field named `:name`. Only
        # `controller`/`action` are swapped — those are required for
        # `controller_name` / `controller_path` / Pundit / instrumentation.
        original_path_parameters = request.path_parameters.dup
        host_path_parameters = {
          controller: host_class.controller_path,
          action: @__ruact_name_sym.to_s
        }
        request.path_parameters = host_path_parameters

        # Thread-local sentinel allows the public action method to be
        # invoked only here, not from a wildcard route the host may have
        # set up — see the guard inside the defined method.
        Thread.current[:__ruact_dispatching] = @__ruact_name_sym
        host_class.dispatch(@__ruact_name_sym.to_s, request, response)
      ensure
        Thread.current[:__ruact_dispatching] = nil
        request.path_parameters = original_path_parameters if original_path_parameters
      end

      # Story 8.3 — positive check for the standalone host shape. A host is
      # standalone iff it's a Module (and not a Class) that extends
      # `Ruact::ServerAction`. The class hierarchy `Class < Module` means
      # `is_a?(Module)` also matches Classes; we exclude Classes explicitly.
      def self.standalone_host?(host)
        return false if host.nil?
        return false if host.is_a?(Class)
        return false unless host.is_a?(Module)

        host.singleton_class.include?(Ruact::ServerAction)
      end

      private

      # Translates a `StandaloneDispatcher::Result` into the appropriate
      # render call. Calling `render` / `head` is what marks the response
      # as performed (`performed? == true`); writing to `response.body =`
      # directly would be overwritten by Rails' `ImplicitRender`.
      def apply_standalone_result(result)
        if result.body.nil? || result.body.empty?
          head(result.status)
        else
          render(
            body: result.body,
            status: result.status,
            content_type: result.content_type
          )
        end
      end

      # Resolves the registry entry BEFORE Rails' before_action chain runs
      # the conditional `verify_authenticity_token` callback — the CSRF
      # decision depends on knowing whether the host is standalone, which
      # is only knowable after we have the entry in hand. Stashes the
      # entry + name on instance ivars so `dispatch_action` and
      # `dispatching_standalone?` can both read them.
      def resolve_ruact_entry!
        @__ruact_name_sym = request.path_parameters[:name].to_s.to_sym
        @__ruact_entry = lookup_entry(@__ruact_name_sym)
      end

      def dispatching_standalone?
        return false unless @__ruact_entry

        Ruact::ServerFunctions::EndpointController.standalone_host?(@__ruact_entry.controller)
      end

      def lookup_entry(name_sym)
        # Story 8.1 only routes through the action registry. Story 9.1 will
        # extend this lookup to also check the query registry; until then,
        # query-only symbols return 404 here.
        Ruact.action_registry.entries[name_sym]
      end

      def render_unknown(name_sym)
        render(
          json: { error: "unknown ruact action: :#{name_sym}" },
          status: :not_found
        )
      end
    end
  end
end
