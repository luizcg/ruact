# frozen_string_literal: true

require "json"
require "timeout"

module Ruact
  # Story 19-1 — the render of a page whose `<Suspense>` content runs after the
  # shell is sent: the shell first, then each boundary, one at a time, in page
  # order, each block evaluated only when its row is due.
  #
  #   run = DeferredRender.new(html, render_context, pipeline)
  #   write(run.shell)
  #   write(run.next_rows) while run.pending?
  #
  # A block runs in the view it was written in, with the template path Rails
  # had when it met the tag, under `Ruact.config.suspense_timeout`. A block
  # that raises, or runs past the timeout, becomes an error row for its
  # boundary — reported through `Rails.error` and logged — and the next block
  # runs. {Flight::Renderer} only ever serializes elements: evaluating, logging
  # and reporting are here, outside `lib/ruact/flight/` (NFR10).
  #
  # Internal API: not part of the public compatibility contract.
  class DeferredRender
    TIMEOUT_DIGEST = "ruact:suspense-timeout"
    ERROR_DIGEST   = "ruact:suspense-error"

    # The content ran past `suspense_timeout`. Its own: a `Timeout::Error` the
    # content raised itself (`Net::ReadTimeout` is one) is the content's error.
    class Expired < StandardError; end

    # What production says about a block that raised: nothing of the error.
    PRODUCTION_MESSAGE = "An error occurred in a <Suspense>"

    # React's development client reads an error's `stack` as frames; a few
    # name the template and the gem without burying the overlay.
    STACK_FRAMES = 12

    # @param html [String] the page ActionView rendered with its blocks kept
    #   (`RenderContext.new(deferring: true)`)
    # @param pipeline [RenderPipeline] the manifest, controller path, logger
    #   and wire flavour the render uses
    # @param guard [#call, nil] wraps each block's evaluation, inside the
    #   timeout: called with a block, returns its value or raises (the
    #   controller's development check for writes the response can no longer
    #   carry)
    def initialize(html, render_context, pipeline, guard: nil)
      @render_context  = render_context
      @manifest        = pipeline.manifest
      @controller_path = pipeline.controller_path
      @development     = pipeline.development
      @logger          = pipeline.logger
      @guard           = guard
      @registry        = []
      @renderer = Flight::Renderer.new(convert(html), @manifest,
                                       strict_serialization: Ruact.config.strict_serialization,
                                       on_as_json_warning: pipeline.as_json_warning_callback,
                                       development: @development)
    end

    # The shell's rows, as one string.
    def shell
      @renderer.shell.join
    end

    # Whether a boundary is still to be rendered.
    def pending?
      @renderer.pending?
    end

    # How many boundaries are still to be rendered.
    def pending_count
      @renderer.pending_count
    end

    # Renders the next boundary and returns its rows, as one string: the rows
    # its content brings and its model row, or an error row.
    def next_rows
      boundary = @renderer.take_boundary
      within_timeout(boundary[:delay]) do
        @renderer.boundary_rows(boundary[:id], content(boundary[:element]))
      end.join
    rescue StandardError => e
      raise if boundary.nil?

      skip_unconverted_components
      report(e, boundary)
      @renderer.error_rows(boundary[:id], error_payload(e), boundary: boundary).join
    end

    private

    # A block that failed may have registered components its HTML, now thrown
    # away, was going to use: the next block's conversion starts after them.
    def skip_unconverted_components
      @registry.fill(nil, @registry.length...@render_context.components.length)
    end

    # The block's HTML as elements; content that is already elements as is.
    def content(element)
      return element unless element.is_a?(Flight::DeferredContent)

      block = @render_context.block(element.key)
      raise Ruact::Error, Flight::DeferredContent::STALE if block.nil?

      html = @guard ? @guard.call { evaluate(block) } : evaluate(block)
      convert(html)
    end

    # Runs the block in its view, with the template path and its local
    # variables as they were when the tag was met, and returns what it wrote.
    # Only what it writes: a value it ends on is not content.
    def evaluate(pending)
      declared = DeclaredContent.take(pending.view) if @development
      html = with_locals(pending.block, pending.locals) { run_in_view(pending) }
      DeclaredContent.check!(pending.view, declared) if declared
      html
    end

    def run_in_view(pending)
      pending.view.instance_exec(pending) do |entry|
        saved = [@virtual_path, @current_template]
        @virtual_path = entry.virtual_path
        @current_template = entry.template
        begin
          capture do
            entry.block.call
            nil
          end
        ensure
          @virtual_path, @current_template = saved
        end
      end
    end

    # Sets the block's local variables to +locals+ while it runs, and back
    # after. A block shares them with the template and with the blocks met
    # after it.
    def with_locals(block, locals)
      return yield if locals.nil? || locals.empty?

      scope = block.binding
      now = locals.keys.to_h { |name| [name, scope.local_variable_get(name)] }
      locals.each { |name, value| scope.local_variable_set(name, value) }
      begin
        yield
      ensure
        now.each { |name, value| scope.local_variable_set(name, value) }
      end
    end

    # The components registered since the last conversion are resolved and
    # added: a block registers its own as it runs. One the manifest cannot
    # resolve fails this conversion and keeps its place (nil), so the next
    # block does not meet it again.
    def convert(html)
      failure = nil
      @render_context.components.drop(@registry.length).each do |entry|
        @registry << @render_context.resolve_entry(entry, @manifest, controller_path: @controller_path)
      rescue StandardError => e
        @registry << nil
        failure ||= e
      end
      raise failure if failure

      HtmlConverter.convert(html.to_s, @registry.compact)
    end

    # The block's `delay` and the block itself, within `suspense_timeout`.
    # `Timeout.timeout` with no exception class unwinds the block with an
    # exception that is not a StandardError, so a `rescue` in the view, or
    # Active Record wrapping what a query raised, cannot take it; it raises
    # `Timeout::Error` out here. It interrupts Ruby code, not a query running
    # inside a database driver that holds the VM lock (measured in 19-0).
    # A `delay` longer than the limit ends in the timeout row at once, as it
    # did before blocks ran later.
    def within_timeout(delay, &)
      limit = Ruact.config.suspense_timeout
      return wait_then(delay, &) unless limit&.positive?
      raise Expired, "the delay (#{delay}s) is longer than suspense_timeout" if delay && delay > limit

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # A query still running at the limit is cancelled on the server, so its
      # connection is free again (Story 19-2, QueryWatch).
      watch = QueryWatch.start(Thread.current, limit)
      begin
        Timeout.timeout(limit) { wait_then(delay, &) }
      rescue Timeout::Error => e
        # Ours only when the limit has passed; earlier, it is the content's.
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < limit

        watch&.cancel_now(Thread.current)
        raise Expired, "ran past suspense_timeout (#{limit}s)", cause: e
      ensure
        watch&.stop
      end
    end

    def wait_then(delay)
      sleep(delay) if delay&.positive?
      yield
    end

    def timed_out?(error)
      error.is_a?(Expired)
    end

    def error_payload(error)
      return Flight::RowEmitter.error_payload("Suspense timeout exceeded", digest: TIMEOUT_DIGEST) if timed_out?(error)
      return Flight::RowEmitter.error_payload(PRODUCTION_MESSAGE, digest: ERROR_DIGEST) unless @development

      payload = Flight::RowEmitter.error_payload("#{error.class}: #{error.message}", digest: ERROR_DIGEST)
      payload["stack"] = development_stack(error)
      payload
    end

    # React's development client reads each frame of `stack` as
    # `[function, file, line, column, enclosing line, enclosing column]` and
    # rebuilds the server's call stack from it. A four-element frame (what this
    # sent before Story 19-2) left the last two undefined, and every frame came
    # out at line 2. Ruby has no column and no enclosing function: column 1,
    # enclosing 0 (none).
    def development_stack(error)
      Array(error.backtrace).first(STACK_FRAMES).filter_map do |frame|
        match = frame.match(/\A(.+?):(\d+)(?::in [`'](.+)')?\z/)
        match && [match[3] || "(ruby)", match[1], Integer(match[2], 10), 1, 0, 0]
      end
    end

    def report(error, boundary)
      what = timed_out?(error) ? "ran past suspense_timeout (#{Ruact.config.suspense_timeout}s)" : "raised"
      @logger&.error("[ruact] <Suspense> content#{where(boundary)} #{what}: #{error.class}: #{error.message}")
      return unless defined?(Rails) && Rails.respond_to?(:error)

      Rails.error.report(error, handled: true, severity: :error, source: "ruact.suspense")
    end

    def where(boundary)
      element = boundary[:element]
      return "" unless element.is_a?(Flight::DeferredContent)

      location = @render_context.block(element.key)&.location
      location ? " at #{location.path}:#{location.lineno}" : ""
    end
  end
end
