# frozen_string_literal: true

require "json"

module Ruact
  module Flight
    # Renders a React element tree to Flight rows, in the order React's client
    # must read them.
    #
    # A render has two parts. The **shell** is every row the page needs to show
    # with its Suspense fallbacks: the imports and model rows the tree
    # references, then the root row. Each **deferred boundary** — the content of
    # a `<Suspense>` — then gets its own rows, one boundary at a time, each
    # preceded by the import and text rows it brings.
    #
    #   renderer = Renderer.new(root, manifest)
    #   renderer.shell                                   # => ["1:I[...]\n", "0:[...]\n"]
    #   renderer.next_boundary(streaming: true) while renderer.pending?
    #
    # A boundary whose content is not rendered yet ({DeferredContent}) is taken
    # with {#take_boundary}, rendered by the caller, and handed back to
    # {#boundary_rows} — or to {#error_rows} when rendering it failed.
    #
    # {.each} and {.render} walk all of it:
    #
    #   Renderer.render(root_element, bundler_config)
    #   # => "1:I[...]\n0:[\"$\",\"div\",...]\n"
    class Renderer
      def self.render(model, bundler_config, **)
        each(model, bundler_config, streaming: false, **).to_a.join
      end

      # Keyword options other than +streaming:+ go to {#initialize}
      # (strict_serialization:, on_as_json_warning:, development:).
      def self.each(model, bundler_config, streaming: true, **, &)
        new(model, bundler_config, **).each(streaming: streaming, &)
      end

      # Whether rows carry the slots React's development client reads (see
      # Serializer#element_tuple): in Rails' development environment only. The
      # test environment keeps the production wire, so what a request spec
      # asserts is what production sends.
      def self.development_default
        return false unless defined?(Rails) && Rails.respond_to?(:env)

        Rails.env.development?
      rescue StandardError
        false
      end

      def initialize(model, bundler_config, strict_serialization: false, on_as_json_warning: nil,
                     development: false)
        @request = Request.new(model, bundler_config,
                               strict_serialization: strict_serialization,
                               on_as_json_warning: on_as_json_warning,
                               development: development)
        @serializer = Serializer.new(@request)
      end

      # The shell's rows: the imports and model rows the tree references, then
      # the root row (id 0). Call once, before {#next_boundary}.
      def shell
        raise Ruact::Error, "ruact: Renderer#shell was already taken" if @shell_taken

        @shell_taken = true
        root_id = @request.allocate_id # => 0
        root_json = JSON.generate(@serializer.serialize_model(@request.root_model))
        @request.take_rows << RowEmitter.model(root_id, root_json)
      end

      # Whether a deferred boundary is still to be rendered.
      def pending?
        @request.deferred?
      end

      # How many deferred boundaries are still to be rendered.
      def pending_count
        @request.deferred_left
      end

      # The rows of the next deferred boundary: the import and text rows its
      # content brings, then its model row. When +streaming+, a boundary with a
      # `delay` waits it first — or, when the delay exceeds `suspense_timeout`,
      # gets an error row instead. For content that is already an element tree;
      # a {DeferredContent} needs {#take_boundary}.
      def next_boundary(streaming:)
        boundary = take_boundary
        # A block this render cannot run: its marker came out of a `cache`
        # block a render that streamed wrote.
        if boundary[:element].is_a?(DeferredContent)
          return error_rows(boundary[:id],
                            RowEmitter.error_payload(DeferredContent::STALE, digest: "ruact:suspense-error"))
        end

        if streaming && boundary[:delay]&.positive?
          timeout = Ruact.config.suspense_timeout
          if timeout&.positive? && boundary[:delay] > timeout
            error = RowEmitter.error_payload("Suspense timeout exceeded", digest: "ruact:suspense-timeout")
            return error_rows(boundary[:id], error)
          end
          sleep(boundary[:delay])
        end

        boundary_rows(boundary[:id], boundary[:element])
      end

      # Takes the next deferred boundary: `{ id:, element:, delay: }`, its
      # content (`element`) still to be rendered. Hand it back, rendered, to
      # {#boundary_rows}, or to {#error_rows}.
      def take_boundary
        raise Ruact::Error, "ruact: Renderer#next_boundary before #shell" unless @shell_taken
        raise Ruact::Error, "ruact: Renderer#next_boundary with no boundary pending" unless pending?

        boundary = @request.next_deferred
        boundary.merge(mark: @request.deferred_count)
      end

      # The rows of a boundary taken with {#take_boundary}, whose content
      # rendered to +element+.
      def boundary_rows(id, element)
        value = @serializer.serialize_model(element)
        @request.take_rows << RowEmitter.model(id, JSON.generate(value))
      end

      # The row of a boundary taken with {#take_boundary} whose content failed
      # to render: an error row with +payload+ ({RowEmitter.error_payload}).
      # The boundaries its content deferred before it failed are dropped (no row
      # references them); the rows it wrote before it failed still go out
      # first, as they may be what a later row needs.
      def error_rows(id, payload, boundary: nil)
        @request.drop_deferred_since(boundary[:mark]) if boundary
        @request.take_rows << RowEmitter.error(id, JSON.generate(payload))
      end

      # Yields every row: the shell, then each deferred boundary.
      # When +streaming+ is false (the initial HTML document), delays are skipped.
      def each(streaming: true, &)
        return enum_for(:each, streaming: streaming) unless block_given?

        shell.each(&)
        next_boundary(streaming: streaming).each(&) while pending?
      end
    end
  end
end
