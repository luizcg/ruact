# frozen_string_literal: true

module Ruact
  module Controller
    # How a rendered ruact page reaches the client: as a Flight body — written
    # all at once, or row by row through `ActionController::Live` — or as an
    # HTML document carrying the payload ({DocumentRendering}). Also the Flight
    # body of a redirect the client router follows itself.
    #
    # Everything that decides what a ruact response looks like on the wire, its
    # headers included, is here.
    module Delivery
      extend ActiveSupport::Concern

      include DocumentRendering

      # The headers of a Flight body written row by row: no caching, and no
      # buffering by a proxy that honours `X-Accel-Buffering` (nginx).
      STREAM_HEADERS = {
        "Content-Type" => "#{RequestKind::FLIGHT_MIME}; charset=utf-8",
        "Cache-Control" => "no-cache",
        "X-Accel-Buffering" => "no"
      }.freeze

      private

      # Build the wire output and write it to the response. Streaming responses
      # only fire after `pipeline.render` returns without raising — that way a
      # missing-component error can still surface as a normal 500 response
      # (matching the legacy `#from_html` ordering) before any streaming
      # response headers are mutated.
      def emit_ruact_response(pipeline, html, render_context, streaming:)
        # Story 15.5 (FR109) — record which page shape ruact rendered so the
        # `Ruact::Server` dev log (`__ruact_log_response_shape!`) can name it and,
        # crucially, stay SILENT on a plain Rails render (this flag is never set
        # there). `@__`-prefixed → never leaks into `view_assigns`.
        @__ruact_negotiated_page = ruact_request? ? :flight : :html_shell
        input = { html: html, render_context: render_context }

        if ruact_request? && streaming
          __ruact_stream_flight(pipeline.render(input, mode: :stream))
        elsif ruact_request?
          render plain: pipeline.render(input, mode: :string), content_type: RequestKind::FLIGHT_MIME
        else
          render_ruact_document(pipeline.render(input, mode: :string))
        end
      end

      # Writes +rows+ (an Enumerator) through `ActionController::Live`'s stream,
      # one write per row, and closes it whatever happens.
      def __ruact_stream_flight(rows)
        STREAM_HEADERS.each { |name, value| response.headers[name] = value }
        begin
          rows.each { |row| response.stream.write(row) }
        ensure
          response.stream.close
        end
      end

      # The Flight body of a redirect: one row the client router reads and
      # follows (`redirectType: "push"`), instead of a 302 the browser would.
      def __ruact_render_flight_redirect(url)
        render plain: "0:#{JSON.generate({ 'redirectUrl' => url, 'redirectType' => 'push' })}\n",
               content_type: RequestKind::FLIGHT_MIME
      end
    end
  end
end
