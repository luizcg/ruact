# frozen_string_literal: true

require "socket"
require_relative "document_rendering"

module Ruact
  module Controller
    # How a rendered ruact page reaches the client: as a Flight body, or as an
    # HTML document carrying the payload ({DocumentRendering}) — all at once,
    # or, in an action that streams ({Streaming}), the shell first and each
    # `<Suspense>`'s rows as its content is rendered. Also the Flight body of a
    # redirect the client router follows itself.
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

      # The same, for a document written in parts.
      DOCUMENT_STREAM_HEADERS = {
        "Content-Type" => "text/html; charset=utf-8",
        "Cache-Control" => "no-cache",
        "X-Accel-Buffering" => "no"
      }.freeze

      # What Rails itself writes once the response has started, on the request's
      # thread, while the first block may be running: the session cookie and the
      # session's own keys (`commit_session`, `commit_flash`, and the CSRF token
      # Rails stores at commit since 7.1), and the headers a middleware adds on
      # the way out. Not the block's writes.
      RAILS_WRITES = {
        "header" => %w[set-cookie server-timing content-security-policy
                       content-security-policy-report-only x-runtime].freeze,
        "session" => %w[session_id flash _csrf_token].freeze
      }.freeze

      # Where a streamed document is cut: the rows of each `<Suspense>` are
      # pushed before it, as they are ready.
      BODY_CLOSE = "</body>"

      private

      # Build the wire output and write it to the response. Nothing is written
      # until the page (or, when it streams, its shell) has rendered without
      # raising — that way a missing-component error still surfaces as a
      # normal 500 response.
      def emit_ruact_response(pipeline, html, render_context, streaming:)
        # Story 15.5 (FR109) — record which page shape ruact rendered so the
        # `Ruact::Server` dev log (`__ruact_log_response_shape!`) can name it and,
        # crucially, stay SILENT on a plain Rails render (this flag is never set
        # there). `@__`-prefixed → never leaks into `view_assigns`.
        @__ruact_negotiated_page = ruact_request? ? :flight : :html_shell
        if streaming
          return __ruact_stream_page(DeferredRender.new(html, render_context, pipeline,
                                                        guard: __ruact_late_write_guard))
        end

        input = { html: html, render_context: render_context }
        if ruact_request?
          render plain: pipeline.render(input, mode: :string), content_type: RequestKind::FLIGHT_MIME
        else
          render_ruact_document(pipeline.render(input, mode: :string))
        end
      end

      # Story 19-1 — the shell, then each boundary as its block is rendered.
      # A page that left nothing for later responds as one that does not stream.
      def __ruact_stream_page(run)
        shell = run.shell
        unless run.pending?
          return render(plain: shell, content_type: RequestKind::FLIGHT_MIME) if ruact_request?

          return render_ruact_document(shell)
        end
        return __ruact_stream(run, STREAM_HEADERS, shell) if ruact_request?

        document = ruact_document_html(shell)
        cut = document.rindex(BODY_CLOSE) || document.length
        __ruact_stream(run, DOCUMENT_STREAM_HEADERS, document[0...cut], document[cut..]) do |rows|
          __ruact_flight_push(rows)
        end
      end

      # Writes +first+, then each boundary's rows (through the block, when given),
      # then +last+. No exception leaves here with the stream open: Live would
      # append Rails' `/500.html` script to a page already on screen. What was
      # not sent stays pending, for the browser's transport to label.
      def __ruact_stream(run, headers, first, last = nil)
        headers.each { |name, value| response.headers[name] = value }
        @__ruact_streamed = true
        stream = response.stream
        begin
          stream.write(first)
          while run.pending?
            if __ruact_client_gone?
              __ruact_log_cut_short(run, "the client left")
              break
            end
            rows = run.next_rows
            stream.write(block_given? ? yield(rows) : rows)
          end
          stream.write(last) if last
        rescue ActionController::Live::ClientDisconnected, IOError, SystemCallError => e
          __ruact_log_cut_short(run, "the client left (#{e.class})")
        rescue StandardError => e
          __ruact_report_stream_error(e, run)
        ensure
          @__ruact_streamed_state = __ruact_response_state if Flight::Renderer.development_default
          stream.close
        end
      end

      # One boundary's rows, as the script a streamed document carries them in:
      # pushed onto the queue the bootstrap reads. Written as
      # {InlineScript.string_literal} writes it — no byte of the payload can
      # close the `<script>`.
      def __ruact_flight_push(rows)
        "<script>(self.__FLIGHT_DATA=self.__FLIGHT_DATA||[]).push(#{InlineScript.string_literal(rows)})</script>"
      end

      # Story 19-1 (D4) — has the client closed its end? Asked before each
      # block: the server does not notice on its own, and a write to a client
      # that left does not fail until the one after it (measured in 19-0).
      # Puma hands the socket over as `puma.socket`; with another server, or
      # none, nothing is asked.
      def __ruact_client_gone?
        socket = request.env["puma.socket"]
        return false if socket.nil? || !socket.respond_to?(:wait_readable) || !socket.wait_readable(0)

        # The end of the connection reads as nil or as "", depending on how the
        # peer closed it.
        socket.recv_nonblock(1, Socket::MSG_PEEK).to_s.empty?
      rescue IO::WaitReadable
        false
      rescue SystemCallError, IOError
        true
      end

      def __ruact_log_cut_short(run, why)
        left = run.pending_count
        logger&.info("[ruact] #{self.class.name}##{action_name}: #{why}; " \
                     "#{left} <Suspense> #{left == 1 ? 'boundary was' : 'boundaries were'} not rendered")
      end

      # An exception once the response has started, outside a block (the end of
      # the layout, the serializer): reported and logged, and the stream closed.
      def __ruact_report_stream_error(error, run)
        logger&.error("[ruact] #{self.class.name}##{action_name} raised while streaming, after the " \
                      "response started: #{error.class}: #{error.message}. The response was closed; " \
                      "#{run.pending_count} <Suspense> boundaries were not rendered.")
        Rails.error.report(error, handled: true, severity: :error, source: "ruact.stream") if Rails.respond_to?(:error)
      end

      # Story 19-1 (D5) — in development, a block that writes a cookie, the
      # session, the flash or a header is an error of that block: the response
      # started before the block ran, so the write would be lost.
      def __ruact_late_write_guard
        return nil unless Flight::Renderer.development_default

        lambda do |&evaluate|
          before = __ruact_response_state
          html = evaluate.call
          changed = __ruact_state_changes(before, __ruact_response_state)
          raise Ruact::Error, __ruact_late_write_message(changed, "a <Suspense>") unless changed.empty?

          html
        end
      end

      # Story 19-1 (D5) — the same, for what runs after the page was sent (an
      # `after_action`): it cannot be a block's error any more, so it is logged.
      def __ruact_check_writes_after_stream
        before = @__ruact_streamed_state
        return if before.nil?

        @__ruact_streamed_state = nil
        changed = __ruact_state_changes(before, __ruact_response_state)
        return if changed.empty?

        logger&.error("[ruact] #{self.class.name}##{action_name}: " \
                      "#{__ruact_late_write_message(changed, 'code after the page was sent')}")
      end

      def __ruact_late_write_message(changed, where)
        "#{where} wrote #{changed.join(', ')} after the response started, so the browser never gets it. " \
          "Status, headers, cookies, the session and the flash are set in the controller, before the page " \
          "renders."
      end

      # What a response can no longer carry once it has started. Each part is
      # read on its own: a controller without a session has no session to read.
      # Reading does not load what is not loaded — the session, the flash — so
      # development behaves as production does.
      def __ruact_response_state
        {
          "header" => __ruact_read_state("header") { response.headers.to_h.transform_keys(&:downcase) },
          "cookie" => __ruact_read_state("cookie") { request.cookie_jar.to_hash.except(__ruact_session_cookie) },
          "session" => __ruact_read_state("session") { session.loaded? ? session.to_hash : {} },
          "flash" => __ruact_read_state("flash") { request.flash_hash&.to_hash || {} }
        }
      end

      def __ruact_read_state(kind)
        yield.except(*RAILS_WRITES.fetch(kind, []))
      rescue StandardError
        nil
      end

      # The session store's cookie: the key the app configured, or the one the
      # store falls back to without one. Not `request.session_options[:key]`:
      # Rack takes the key out of the options it keeps.
      def __ruact_session_cookie
        key = Rails.application.config.session_options[:key]
        key ||= request.session.instance_variable_get(:@by).try(:key)
        (key || "_session_id").to_s
      rescue StandardError
        "_session_id"
      end

      # `["the cookie theme", "the header X-Trace"]` — what differs.
      def __ruact_state_changes(before, after)
        before.flat_map do |kind, was|
          now = after[kind]
          next [] if was.nil? || now.nil? || was == now

          (was.keys | now.keys).reject { |key| was[key] == now[key] }.map { |key| "the #{kind} #{key}" }
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
