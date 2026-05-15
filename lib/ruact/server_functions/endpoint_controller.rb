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
      # Story 8.1 AC8 — the gem does NOT impose its own CSRF protection. The
      # host's `ApplicationController` is what enforces `protect_from_forgery`;
      # since requests are dispatched THROUGH a fresh host-controller instance
      # below, the host's CSRF rules apply. EndpointController itself only
      # routes — never renders the host's content directly.
      #
      # We skip CSRF on EndpointController explicitly because Rails 8's
      # default `ActionController::Base` includes `protect_from_forgery` and
      # we don't want the endpoint to reject a request before the host
      # controller has a chance to apply its own forgery policy. The host
      # controller's `protect_from_forgery` (run inside `dispatch_action`)
      # is what actually enforces. Skipping here is the moral equivalent of
      # the engine-controller pattern in Rails.
      skip_forgery_protection if respond_to?(:skip_forgery_protection)

      # `POST /__ruact/fn/:name` (mounted by `Ruact::Railtie`).
      def dispatch_action
        # Re-run-2 (2026-05-14) — read `:name` from `request.path_parameters`,
        # NOT `params[:name]`. The latter triggers eager body parsing (Rails'
        # `ActionController::StrongParameters#params` merges body + query +
        # path params); a malformed JSON body for an unknown action would
        # raise `ActionDispatch::Http::Parameters::ParseError` BEFORE the
        # 404 path runs, hiding the real failure shape from the client.
        raw_name = request.path_parameters[:name].to_s
        name_sym = raw_name.to_sym
        entry = lookup_entry(name_sym)
        return render_unknown(name_sym) unless entry

        host_class = entry.controller
        unless host_class.is_a?(Class)
          return render(
            json: { error: "ruact action :#{name_sym} has no associated controller" },
            status: :internal_server_error
          )
        end

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
          action: name_sym.to_s
        }
        request.path_parameters = host_path_parameters

        # Thread-local sentinel allows the public action method to be
        # invoked only here, not from a wildcard route the host may have
        # set up — see the guard inside the defined method.
        Thread.current[:__ruact_dispatching] = name_sym
        host_class.dispatch(name_sym.to_s, request, response)
      ensure
        Thread.current[:__ruact_dispatching] = nil
        request.path_parameters = original_path_parameters if original_path_parameters
      end

      private

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
