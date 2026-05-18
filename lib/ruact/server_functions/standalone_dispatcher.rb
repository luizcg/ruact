# frozen_string_literal: true

require "json"

module Ruact
  module ServerFunctions
    # Story 8.3 — execution path for STANDALONE server actions (host
    # modules that `extend Ruact::ServerAction`). Invoked by
    # {Ruact::ServerFunctions::EndpointController#dispatch_action} when
    # the resolved registry entry's host is a Module rather than an
    # `ActionController::Base` subclass.
    #
    # Differences from the controller-hosted path (Story 8.1):
    #   - No `host_class.dispatch` — no Rails `process_action` callback
    #     chain, no `before_action` filters, no `rescue_from` on the host.
    #     The dispatcher is in charge of the entire response cycle.
    #   - The block runs via `instance_exec` on a fresh
    #     {Ruact::ServerFunctions::StandaloneContext}, not on a controller
    #     instance. The context exposes `params` / `session` /
    #     `current_user` / `request` / `cookies` / `headers`; it does NOT
    #     expose `render` / `redirect_to` / `head` (the block's return
    #     value IS the response).
    #
    # Same contract for response shape (parity with Story 8.1):
    #   - `nil` block return                          → 204 No Content
    #   - Hash / Array / scalar block return          → 200 + JSON body
    #   - `raise Ruact::ActionError.new(status:, body:)` → that status + JSON body
    class StandaloneDispatcher
      # Plain value object returned by {.dispatch}. The caller — typically
      # {EndpointController#dispatch_action} when running inside the Rails
      # request cycle — applies these directives via `render` / `head` so
      # Rails' `ImplicitRender` does not overwrite the response. In test
      # / benchmark contexts the value can be applied to a bare response
      # via {.apply_to_response}.
      Result = Struct.new(:status, :body, :content_type)

      class << self
        # @param entry [Ruact::ServerFunctions::RegistryEntry]
        # @param request [ActionDispatch::Request]
        # @param response [ActionDispatch::Response, nil] when non-nil, the
        #   dispatcher writes directives onto the response and marks it
        #   committed. Tests typically pass nil and apply the Result manually.
        # @return [Result] render directive describing the response.
        def dispatch(entry, request, response = nil)
          begin
            raw_args = extract_args(request)
          rescue JSON::ParserError => e
            # Story 8.3 review R3 — mirror the controller-DSL path's
            # structured 400 contract (see `Ruact::Controller#ruact_action`,
            # Re-run-4 2026-05-15). A malformed `application/json` body
            # is a client bug; surface it as JSON {error} + 400 so the
            # runtime's RuactActionError surface reports it cleanly.
            result = build_malformed_json_result(entry, e)
            apply_to_response(result, response) if response
            return result
          end

          params = ActionController::Parameters.new(raw_args)
          context = StandaloneContext.new(params: params, request: request)

          result =
            begin
              raw = context.instance_exec(params, &entry.block)
              build_success_result(raw)
            rescue Ruact::ActionError => e
              build_error_result(e)
            end

          maybe_warn_unread_current_user(entry, context)
          apply_to_response(result, response) if response
          result
        end

        # Writes a {Result} onto an `ActionDispatch::Response`. Used by
        # tests/benches that drive the dispatcher directly (the
        # request-cycle path goes through `EndpointController#dispatch_action`
        # which calls `render` / `head` so Rails' `ImplicitRender` does
        # not interfere).
        def apply_to_response(result, response)
          response.status = result.status
          if result.body.nil? || result.body.empty?
            response.headers.delete("Content-Type")
            response.body = ""
          else
            response.headers["Content-Type"] = result.content_type if result.content_type
            response.body = result.body
          end
        end

        private

        # Mirrors {Ruact::Controller#ruact_action_raw_args}'s content-type
        # routing so the block's `params` shadow looks identical regardless
        # of host shape.
        def extract_args(request)
          content_type = request.content_mime_type&.to_s ||
                         request.headers["Content-Type"]&.to_s&.split(";")&.first
          case content_type
          when "application/json"
            body = request.raw_post
            return {} if body.nil? || body.empty?

            parsed = JSON.parse(body)
            parsed.is_a?(Hash) ? parsed : { "_value" => parsed }
          when "multipart/form-data", "application/x-www-form-urlencoded"
            request.request_parameters
          else
            {}
          end
        end

        # Story 8.3 review R3 — structured 400 for malformed JSON bodies,
        # parity with the controller-DSL path (controller.rb:301-313).
        def build_malformed_json_result(entry, parse_error)
          Result.new(
            status: 400,
            body: JSON.generate(
              error: "ruact action :#{entry.ruby_symbol} received malformed JSON body: #{parse_error.message}"
            ),
            content_type: "application/json; charset=utf-8"
          )
        end

        def build_success_result(raw)
          if raw.nil?
            Result.new(status: 204, body: nil, content_type: nil)
          else
            Result.new(
              status: 200,
              body: JSON.generate(raw),
              content_type: "application/json; charset=utf-8"
            )
          end
        end

        def build_error_result(action_error)
          status = action_error.status.is_a?(Symbol) ? status_code_for(action_error.status) : action_error.status
          body = action_error.body
          if body.nil?
            Result.new(status: status, body: nil, content_type: nil)
          else
            Result.new(
              status: status,
              body: JSON.generate(body),
              content_type: "application/json; charset=utf-8"
            )
          end
        end

        def status_code_for(symbol)
          if defined?(Rack::Utils::SYMBOL_TO_STATUS_CODE)
            Rack::Utils::SYMBOL_TO_STATUS_CODE.fetch(symbol)
          else
            symbol
          end
        end

        # Pitfall #4 — dev-only warning when a standalone action never
        # reads `current_user` even though a resolver IS configured. The
        # warning is gated on `Rails.env.development?` so production hosts
        # that deliberately expose unauthenticated actions don't see spam.
        def maybe_warn_unread_current_user(entry, context)
          return unless defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:development?)
          return unless Rails.env.development?
          return if Ruact.config.current_user_resolver.nil?
          return if context.__ruact_current_user_read?

          host_name = entry.controller.respond_to?(:name) ? entry.controller.name : entry.controller.inspect
          Rails.logger&.warn(
            "[ruact] WARNING — standalone action :#{entry.ruby_symbol} on #{host_name} returned " \
            "without ever reading `current_user`. Standalone actions have NO implicit authorization; " \
            "ensure the block calls `current_user` (or equivalent) before exposing protected data."
          )
        end
      end
    end
  end
end
