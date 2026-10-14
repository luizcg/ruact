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
        root_id = @request.allocate_id # => 0
        root_json = JSON.generate(@serializer.serialize_model(@request.root_model))
        @request.take_rows << RowEmitter.model(root_id, root_json)
      end

      # Whether a deferred boundary is still to be rendered.
      def pending?
        @request.deferred?
      end

      # The rows of the next deferred boundary: the import and text rows its
      # content brings, then its model row. When +streaming+, a boundary with a
      # `delay` waits it first — or, when the delay exceeds `suspense_timeout`,
      # gets an error row instead.
      def next_boundary(streaming:)
        deferred = @request.next_deferred
        if streaming && deferred[:delay]&.positive?
          timeout = Ruact.config.suspense_timeout
          if timeout&.positive? && deferred[:delay] > timeout
            error = RowEmitter.error_payload("Suspense timeout exceeded", digest: "ruact:suspense-timeout")
            return [RowEmitter.error(deferred[:id], JSON.generate(error))]
          end
          sleep(deferred[:delay])
        end

        value = @serializer.serialize_model(deferred[:element])
        @request.take_rows << RowEmitter.model(deferred[:id], JSON.generate(value))
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
