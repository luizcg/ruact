# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # Story 9.4 (D3) — per-request execution context injected into a
    # {Ruact::Query} subclass by the internal query dispatch controller. A
    # fresh instance is built per request (NFR8) wrapping the DISPATCHING
    # controller instance; because that controller inherits
    # `Ruact.config.query_parent_controller`, every delegated reader resolves
    # to the host's own machinery — `current_user` IS the host's method
    # (Devise / Pundit / hand-rolled), not a gem-side resolver lambda.
    #
    # Mirrors the SHAPE of the Story-8.3 `StandaloneContext` (plain accessors,
    # per-request instance) while sourcing everything from the controller —
    # the resolver-lambda pattern is superseded by the 2026-06-02 ADR
    # addendum (Decision 2).
    class QueryContext
      # @param controller [ActionController::Base] the dispatching controller
      #   instance (a generated subclass of `Ruact.config.query_parent_controller`).
      def initialize(controller:)
        @controller = controller
      end

      # The host's authenticated user. Resolved through the controller's own
      # `current_user` — public OR private (hand-rolled apps commonly define
      # it `private`). When the host chain defines no `current_user` at all,
      # raises a NoMethodError that names the fix instead of a bare
      # "undefined method" from deep inside a query body.
      #
      # @return [Object, nil]
      # @raise [NoMethodError] when the parent controller chain defines no
      #   `current_user`.
      def current_user
        unless @controller.respond_to?(:current_user, true)
          raise NoMethodError,
                "ruact: the query dispatch controller (inheriting " \
                "#{@controller.class.superclass.name}, via Ruact.config.query_parent_controller) " \
                "does not define `current_user`. Define it on the parent controller, or point " \
                "`query_parent_controller` at a controller that does."
        end

        @controller.send(:current_user)
      end

      # @return [ActionController::Parameters] the request params (query-string
      #   parameters on a GET query route).
      def params
        @controller.params
      end

      # @return [ActionDispatch::Request] the live request.
      def request
        @controller.request
      end

      # @return [ActionDispatch::Request::Session] the host middleware's session.
      def session
        @controller.session
      end
    end
  end
end
