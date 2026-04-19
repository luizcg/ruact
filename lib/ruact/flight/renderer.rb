# frozen_string_literal: true

require "json"

module Ruact
  module Flight
    # Renders a React element tree to a Flight wire format string.
    #
    # Usage:
    #   output = Renderer.render(root_element, bundler_config)
    #   # => "1:I[...]\n0:[\"$\",\"div\",...]\n"
    class Renderer
      def self.render(model, bundler_config, **)
        each(model, bundler_config, streaming: false, **).to_a.join
      end

      def self.each(model, bundler_config, strict_serialization: false, on_as_json_warning: nil,
                    streaming: true, &)
        new(model, bundler_config,
            strict_serialization: strict_serialization,
            on_as_json_warning: on_as_json_warning).each(streaming: streaming, &)
      end

      def initialize(model, bundler_config, strict_serialization: false, on_as_json_warning: nil)
        @request = Request.new(model, bundler_config,
                               strict_serialization: strict_serialization,
                               on_as_json_warning: on_as_json_warning)
      end

      # Yields Flight rows one at a time.
      # Flush order: imports → regular → root → deferred (with optional delay) → errors.
      # When streaming: false (initial HTML shell), deferred delays are skipped.
      def each(streaming: true, &block)
        return enum_for(:each, streaming: streaming) unless block_given?

        root_id = @request.allocate_id # => 0

        serializer = Serializer.new(@request)
        root_value = serializer.serialize_model(@request.root_model)
        root_json  = JSON.generate(root_value)
        root_row   = RowEmitter.model(root_id, root_json)

        @request.completed_import_chunks.each(&block)
        @request.completed_regular_chunks.each(&block)
        yield root_row

        # Deferred chunks: emitted after root, optionally delayed (Suspense streaming).
        # When the chunk delay exceeds suspense_timeout, an E-type error row is emitted instead.
        @request.deferred_chunks.each do |deferred|
          if streaming && deferred[:delay]&.positive?
            timeout = Ruact.config.suspense_timeout
            if timeout&.positive? && deferred[:delay] > timeout
              yield RowEmitter.error(deferred[:id], JSON.generate("Suspense timeout exceeded"))
              next
            end
            sleep(deferred[:delay])
          end

          # Serialize deferred content — may produce new import rows
          import_count_before = @request.completed_import_chunks.length
          deferred_value = serializer.serialize_model(deferred[:element])

          # Yield any import rows discovered during deferred serialization
          @request.completed_import_chunks[import_count_before..].each(&block)

          yield RowEmitter.model(deferred[:id], JSON.generate(deferred_value))
        end

        @request.completed_error_chunks.each(&block)
      end
    end
  end
end
