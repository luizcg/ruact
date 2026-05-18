# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 8.3 — per-dispatch execution context for a standalone server
    # action. The dispatcher allocates a fresh instance per request,
    # `instance_exec`s the action block against it, and discards the
    # instance once the response is written.
    #
    # Exposes:
    #   - `params`   — the action-call args, as `ActionController::Parameters`
    #     (same shape as the controller-hosted path from Story 8.1).
    #   - `request`  — the live `ActionDispatch::Request`.
    #   - `session`  — the host middleware's session.
    #   - `cookies`  — the live `ActionDispatch::Cookies::CookieJar`.
    #   - `headers`  — `request.headers`.
    #   - `current_user` — memoized; reads `request.env['ruact.current_user']`
    #     when present, otherwise invokes
    #     {Ruact::Configuration#current_user_resolver} (a lambda taking
    #     `request.env`). Raises {Ruact::CurrentUserNotConfiguredError} when
    #     neither path yields a value AND the block actually reads it.
    #
    # Does NOT expose `render` / `redirect_to` / `head` — those are
    # controller-context methods. The block's return value IS the response;
    # raise {Ruact::ActionError} for non-2xx returns.
    class StandaloneContext
      attr_reader :params, :request

      # @param params [ActionController::Parameters] action-call args.
      # @param request [ActionDispatch::Request] the live request.
      def initialize(params:, request:)
        @params = params
        @request = request
        @current_user_read = false
        @current_user_memo = nil
        @current_user_resolved = false
      end

      def session
        @request.session
      end

      def cookies
        @request.cookie_jar
      end

      def headers
        @request.headers
      end

      # Memoized current_user accessor. Sets a flag so the dispatcher can
      # emit a dev-only warning when a block never reads `current_user`
      # (Pitfall #4 in the story spec).
      def current_user
        @current_user_read = true
        return @current_user_memo if @current_user_resolved

        env = @request.env
        if env.key?("ruact.current_user")
          @current_user_memo = env["ruact.current_user"]
          @current_user_resolved = true
          return @current_user_memo
        end

        resolver = Ruact.config.current_user_resolver
        raise Ruact::CurrentUserNotConfiguredError unless resolver

        @current_user_memo = resolver.call(env)
        @current_user_resolved = true
        @current_user_memo
      end

      # @api private — Pitfall #4 dev-mode warning flag.
      def __ruact_current_user_read?
        @current_user_read
      end

      # Inhibits accidental controller-context calls inside a standalone
      # block. The error message names the supported alternatives so the
      # developer can immediately fix the call.
      def render(*_args, **_kwargs)
        raise NoMethodError,
              "StandaloneContext does not expose `render` — return a value from " \
              "the block (it becomes the JSON response) or raise " \
              "`Ruact::ActionError.new(status:, body:)` for non-2xx responses."
      end

      def redirect_to(*_args, **_kwargs)
        raise NoMethodError,
              "StandaloneContext does not expose `redirect_to` — return a value " \
              "from the block (it becomes the JSON response) or raise " \
              "`Ruact::ActionError.new(status:, body:)` for non-2xx responses."
      end

      def head(*_args, **_kwargs)
        raise NoMethodError,
              "StandaloneContext does not expose `head` — return `nil` to render " \
              "204 No Content, or raise `Ruact::ActionError.new(status:, body:)` " \
              "for other non-2xx responses."
      end
    end
  end
end
