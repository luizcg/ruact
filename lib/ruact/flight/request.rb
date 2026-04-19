# frozen_string_literal: true

module Ruact
  module Flight
    # Central state for a single Flight render.
    # Owns the ID allocator, chunk queues, and dedup tracker.
    class Request
      # I rows — flushed first
      attr_reader :completed_import_chunks
      # model rows
      attr_reader :completed_regular_chunks
      # E rows — flushed last
      attr_reader :completed_error_chunks
      # { id:, element:, delay: } — emitted after root row
      attr_reader :deferred_chunks
      # object_id => "$L<hex>" reference (dedup)
      attr_reader :written_objects
      attr_reader :next_chunk_id, :pending_chunks, :bundler_config, :root_model,
                  :strict_serialization, :on_as_json_warning

      def initialize(model, bundler_config, strict_serialization: false, on_as_json_warning: nil)
        @strict_serialization = strict_serialization
        @on_as_json_warning   = on_as_json_warning
        @next_chunk_id = 0
        @pending_chunks = 0
        @bundler_config = bundler_config

        @completed_import_chunks  = []
        @completed_regular_chunks = []
        @completed_error_chunks   = []
        @deferred_chunks          = []

        @written_objects = {}.compare_by_identity

        # Root task is always ID 0
        @root_model = model
      end

      def allocate_id
        id = @next_chunk_id
        @next_chunk_id += 1
        id
      end

      def increment_pending
        @pending_chunks += 1
      end

      def decrement_pending
        @pending_chunks -= 1
      end
    end
  end
end
