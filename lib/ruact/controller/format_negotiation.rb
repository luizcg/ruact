# frozen_string_literal: true

module Ruact
  module Controller
    # Story 17-0j — a router request answers as `format.html`.
    #
    # The ruact router asks for a page with `Accept: text/x-component`, which is
    # not a Rails MIME type: the request negotiated no format at all, and every
    # `respond_to` raised `ActionController::UnknownFormat` (406) on a
    # navigation or a form submit. That is the controller Rails' own scaffold
    # writes. A router request asks for the PAGE, the same thing a browser's
    # `text/html` asks for, so it now negotiates `:html` — unless the URL names
    # a format (`/posts/1.json`), which wins as it always has. Whether the
    # answer is Flight or an HTML document is still ruact's decision, read from
    # the Accept header, not from the negotiated format.
    module FormatNegotiation
      extend ActiveSupport::Concern

      # Rails' negotiated-formats slot on the request. Writing it directly,
      # rather than `request.format =`, leaves `params[:format]` alone.
      FORMATS_KEY = "action_dispatch.request.formats"

      included do
        # A plain object including the concern (unit specs, a hand-rolled
        # controller) has no callback chain to join.
        prepend_before_action :__ruact_negotiate_router_request_as_html if respond_to?(:prepend_before_action)
      end

      # `respond_to` with no `format.html` still answers 406 to a router
      # request, as Rails does to a browser — with the reason and the fix.
      #
      # @see ActionController::MimeResponds#respond_to
      def respond_to(*mimes, &)
        super
      rescue ActionController::UnknownFormat
        raise unless ruact_request?

        raise ActionController::UnknownFormat,
              "#{self.class.name}##{action_name} was asked for its page by the ruact router, which " \
              "negotiates format.html, and its respond_to has no format.html branch. Add one, or " \
              "link to this action with data-ruact=\"false\" so the browser loads it."
      end

      private

      def __ruact_negotiate_router_request_as_html
        return unless ruact_request?
        return if params[:format].present?

        request.set_header(FORMATS_KEY, [Mime[:html]])
      end
    end
  end
end
