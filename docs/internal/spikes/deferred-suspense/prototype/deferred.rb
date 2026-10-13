# frozen_string_literal: true

# Story 19-0 — the prototype. It lives here, patches the gem at load time, and
# is not shipped: the point is to find out what deferred evaluation takes, not
# to be its implementation.
#
# What it changes, in the order a request meets it:
#
#   1. ErbPreprocessor  the content between <Suspense> and </Suspense> becomes
#                       the block of a helper call, so evaluating the template
#                       no longer evaluates it.
#   2. the helper       registers the block (with the view it closes over) in
#                       the render context and leaves a marker in the HTML.
#   3. HtmlConverter    turns the marker into a Suspense whose child is a
#                       reference to the registered block.
#   4. Run              serializes the shell, then — one block at a time, after
#                       the shell has been written — evaluates a block, converts
#                       its HTML and serializes its row. The serializer never
#                       calls a block: it only ever sees elements.
#   5. Delivery         writes the shell first and each row as it is ready,
#                       through ActionController::Live or through a lazy Rack
#                       body, for a Flight navigation and for the document.

require "timeout"
require_relative "entry_tags"

module Spike
  module Deferred
    Pending = Struct.new(:view, :block, :virtual_path, :current_template)
    Ref = Struct.new(:index)

    class SuspenseTimeout < StandardError; end

    # 2a. Where the blocks wait.
    module RenderContextExt
      def deferred_blocks
        @deferred_blocks ||= []
      end

      def register_deferred(pending)
        deferred_blocks << pending
        deferred_blocks.length - 1
      end
    end

    # 1. <ruact-suspense …>content</ruact-suspense>, as the released
    # preprocessor leaves it, becomes a block.
    module PreprocessorExt
      OPEN  = /<ruact-suspense([^>]*)>/
      CLOSE = "</ruact-suspense>"

      def transform(source, **)
        super
          .gsub(OPEN) { "<%= __ruact_deferred__(#{::Regexp.last_match(1).inspect}) do %>" }
          .gsub(CLOSE, "<% end %>")
      end
    end

    # 2b. The helper the template now calls. `self` is the view.
    module ViewHelperExt
      def __ruact_deferred__(attributes, &block)
        context = @ruact_render_context
        # No render in flight (a plain Rails render of this template): as today.
        return "<ruact-suspense#{attributes}>#{capture(&block)}</ruact-suspense>".html_safe if context.nil?

        index = context.register_deferred(Pending.new(self, block, @virtual_path, @current_template))
        %(<ruact-suspense#{attributes} data-ruact-deferred="#{index}"></ruact-suspense>).html_safe
      end
    end

    # 3. The marker becomes a Suspense whose child is a reference.
    module HtmlConverterExt
      def convert_suspense_element(node)
        element = super
        index = node["data-ruact-deferred"]
        return element if index.nil?

        Ruact::Flight::SuspenseElement.new(fallback: element.fallback, children: Ref.new(Integer(index)), delay: 0)
      end
    end

    # 4. One render: the shell now, each deferred row when asked.
    class Run
      def initialize(html, render_context, manifest, controller_path:, development:)
        @render_context  = render_context
        @manifest        = manifest
        @controller_path = controller_path
        @development     = development
        @request = Ruact::Flight::Request.new(convert(html), manifest,
                                              strict_serialization: Ruact.config.strict_serialization,
                                              development: development)
        @serializer = Ruact::Flight::Serializer.new(@request)
        @imports = 0
        @regular = 0
        @next = 0
      end

      # Imports, model rows and the root row: everything the page needs to show
      # with its fallbacks.
      def shell
        root_id = @request.allocate_id
        root = Ruact::Flight::RowEmitter.model(root_id, JSON.generate(@serializer.serialize_model(@request.root_model)))
        (new_rows << root).join
      end

      def pending?
        @next < @request.deferred_chunks.length
      end

      # Evaluates the next block and returns its rows. A block that raises, or
      # runs past `suspense_timeout`, becomes an error row for its boundary.
      def next_rows
        deferred = @request.deferred_chunks[@next]
        @next += 1
        element = deferred[:element]
        element = evaluate(element) if element.is_a?(Ref)
        value = @serializer.serialize_model(element)
        (new_rows << Ruact::Flight::RowEmitter.model(deferred[:id], JSON.generate(value))).join
      rescue StandardError => e
        Events.add("block_error:#{e.class}")
        Rails.error.report(e, handled: true, source: "ruact.suspense")
        Rails.logger.error("[ruact] <Suspense> content raised #{e.class}: #{e.message}")
        Ruact::Flight::RowEmitter.error(deferred[:id], JSON.generate(error_payload(e)))
      end

      # What is left when the response ends early.
      def skipped
        @request.deferred_chunks.length - @next
      end

      private

      def convert(html)
        registry = @render_context.components.map do |entry|
          ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
          { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
        end
        Ruact::HtmlConverter.convert(html, registry)
      end

      # The block runs in the view it was written in, with the template path
      # Rails had while rendering it (`t(".key")` reads it).
      def evaluate(ref)
        pending = @render_context.deferred_blocks.fetch(ref.index)
        Events.add("block_start:#{ref.index}")
        html = within_timeout { capture(pending) }
        Events.add("block_end:#{ref.index}")
        convert(html)
      end

      def capture(pending)
        restore_path = ENV["SPIKE_NO_VPATH"] != "1"
        pending.view.instance_exec do
          saved = [@virtual_path, @current_template]
          if restore_path
            @virtual_path = pending.virtual_path
            @current_template = pending.current_template
          end
          begin
            capture(&pending.block)
          ensure
            @virtual_path, @current_template = saved
          end
        end
      end

      def within_timeout(&)
        limit = Ruact.config.suspense_timeout
        return yield unless limit&.positive?

        Timeout.timeout(limit, SuspenseTimeout, &)
      end

      def new_rows
        imports = @request.completed_import_chunks[@imports..]
        regular = @request.completed_regular_chunks[@regular..]
        @imports = @request.completed_import_chunks.length
        @regular = @request.completed_regular_chunks.length
        imports + regular
      end

      def error_payload(error)
        return Ruact::Flight::RowEmitter.error_payload("Suspense timeout exceeded", digest: "ruact:suspense-timeout") if timed_out?(error)

        message = @development ? "#{error.class}: #{error.message}" : "An error occurred in a <Suspense>"
        payload = Ruact::Flight::RowEmitter.error_payload(message, digest: "ruact:suspense-error")
        payload["stack"] = dev_stack(error) if @development
        payload
      end

      # Raised inside a query, the timeout arrives wrapped (ActiveRecord::StatementInvalid).
      def timed_out?(error)
        while error
          return true if error.is_a?(SuspenseTimeout)

          error = error.cause
        end
        false
      end

      # React's development client reads `stack` as [function, file, line, column] frames.
      def dev_stack(error)
        Array(error.backtrace).first(8).filter_map do |frame|
          match = frame.match(/\A(.+?):(\d+)(?::in [`'](.+)')?\z/)
          match && [match[3] || "(ruby)", match[1], Integer(match[2]), 0]
        end
      end
    end
  end

  # 5. Shell first, then each row as its block finishes.
  module Delivery
    private

    def emit_ruact_response(_pipeline, html, render_context, streaming:) # rubocop:disable Lint/UnusedMethodArgument
      @__ruact_negotiated_page = ruact_request? ? :flight : :html_shell
      run = Deferred::Run.new(html, render_context, ruact_manifest,
                              controller_path: controller_path,
                              development: Ruact::Flight::Renderer.development_default)
      shell = run.shell

      # Nothing deferred: the response ruact sends today, byte for byte.
      unless run.pending?
        return render(plain: shell, content_type: "text/x-component") if ruact_request?

        return render_ruact_document(shell)
      end

      if ruact_request?
        stream_headers("text/x-component; charset=utf-8")
        deliver(run, first: shell)
      else
        head, tail = split_document(shell)
        stream_headers("text/html; charset=utf-8")
        deliver(run, first: head, last: tail) { |rows| flight_push(rows) }
      end
    end

    def stream_headers(content_type)
      response.headers["Content-Type"] = content_type
      return if ENV["SPIKE_BARE_HEADERS"] == "1"

      response.headers["Cache-Control"]     = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
    end

    # The document the layout renders, cut before </body>: the rows that come
    # later are pushed from there.
    def split_document(shell)
      @ruact_flight_payload = shell
      document = render_to_string(html: "".html_safe, layout: Ruact.config.layout)
      cut = document.rindex("</body>") || document.length
      [document[0...cut], document[cut..]]
    ensure
      remove_instance_variable(:@ruact_flight_payload) if instance_variable_defined?(:@ruact_flight_payload)
    end

    def flight_push(rows)
      json = JSON.generate(rows).gsub(/[<>&\u2028\u2029]/) { |char| format("\\u%04x", char.ord) }
      "<script>self.__FLIGHT_DATA.push(#{json})</script>"
    end

    def deliver(run, first:, last: nil, &wrap)
      wrap ||= ->(rows) { rows }
      produce = lambda do |write|
        write.call(first)
        Events.add("shell_written")
        while run.pending?
          if client_gone?
            Events.add("client_gone:skipped=#{run.skipped}")
            break
          end
          write.call(wrap.call(run.next_rows))
        end
        write.call(last) if last
        Events.add("complete")
      end
      SPIKE_MODE == "live" ? deliver_live(run, produce) : deliver_body(run, produce)
    end

    # Has the client closed its end? Asked before each block (SPIKE_PEEK=1): a
    # write to a socket the peer closed does not fail until the one after it.
    # Puma hands the socket over as `puma.socket`; Rack has no portable way.
    def client_gone?
      return false unless ENV["SPIKE_PEEK"] == "1"

      socket = request.env["puma.socket"]
      return false if socket.nil? || !socket.wait_readable(0)

      socket.recv_nonblock(1, Socket::MSG_PEEK).empty?
    rescue IO::WaitReadable
      false
    rescue SystemCallError, IOError
      true
    end

    # ActionController::Live: this runs inside the action, which Live runs in a
    # thread of its own. The filters around the action are still on the stack.
    def deliver_live(run, produce)
      produce.call(->(chunk) { response.stream.write(chunk) })
    rescue ActionController::Live::ClientDisconnected
      Events.add("disconnected:skipped=#{run.skipped}")
    ensure
      response.stream.close
    end

    # A lazy Rack body: the action returns now, and the server runs `each`
    # after the filters and the middleware have returned.
    def deliver_body(run, produce)
      self.response_body = LazyBody.new(run, produce)
    end
  end

  class LazyBody
    def initialize(run, produce)
      @run = run
      @produce = produce
      @finished = false
    end

    def each(&write)
      @produce.call(write)
      @finished = true
    end

    def close
      Events.add("disconnected:skipped=#{@run.skipped}") unless @finished
    end
  end
end

Ruact::RenderContext.include(Spike::Deferred::RenderContextExt)
Ruact::ErbPreprocessor.prepend(Spike::Deferred::PreprocessorExt)
Ruact::HtmlConverter.prepend(Spike::Deferred::HtmlConverterExt)
ActiveSupport.on_load(:action_view) { include Spike::Deferred::ViewHelperExt }
