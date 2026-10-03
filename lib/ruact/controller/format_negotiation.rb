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

      # `respond_to` with no `format.html` still answers 406 to a router
      # request, as Rails does to a browser — with the reason and the fix. Only
      # when THIS respond_to found no format: an UnknownFormat raised inside a
      # branch (a nested respond_to, an explicit raise), or one for a format
      # the URL named, keeps Rails' own message.
      #
      # @see ActionController::MimeResponds#respond_to
      def respond_to(*mimes, &block)
        collector = nil
        recording = block && lambda { |given|
          collector = given
          yield(given)
        }
        super(*mimes, &recording)
      rescue ActionController::UnknownFormat
        raise unless __ruact_router_found_no_format?(collector, mimes)

        raise ActionController::UnknownFormat,
              "#{self.class.name}##{action_name} was asked for its page by the ruact router, which " \
              "negotiates format.html, and its respond_to has no format.html branch. Add one, or " \
              "link to this action with data-ruact=\"false\" so the browser loads it."
      end

      private

      # Before every callback — a host's own `prepend_before_action` included —
      # since this sits above AbstractController::Callbacks in the chain. An
      # auth callback that answers with `respond_to` gets the format too.
      def process_action(...)
        __ruact_negotiate_router_request_as_html
        super
      end

      def __ruact_negotiate_router_request_as_html
        return unless ruact_request?
        return if __ruact_url_format.present?

        request.set_header(FORMATS_KEY, [Mime[:html]])
      end

      # The format the URL names (`/posts/1.json`, `?format=json`). Read from
      # the path and query only: this runs before Rails' rescue and logging,
      # where parsing a malformed request BODY must not raise.
      def __ruact_url_format
        request.path_parameters[:format] || request.query_parameters[:format]
      rescue ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError
        nil
      end

      def __ruact_router_found_no_format?(collector, mimes)
        return false unless ruact_request? && __ruact_url_format.blank?

        if collector
          collector.format.nil?
        else
          request.negotiate_mime(mimes.map { |mime| Mime[mime] }).nil?
        end
      end
    end
  end
end
