# frozen_string_literal: true

module Ruact
  module Flight
    # Central state for a single Flight render: the id allocator, the rows the
    # serializer has written and not yet handed out, the deferred boundaries
    # still to render, and the client-reference de-duplication table.
    #
    # The serializer writes rows here ({#add_import}, {#add_row}) and defers
    # Suspense content ({#defer}); {Renderer} takes them in the order the
    # client must read them ({#take_rows}, {#next_deferred}).
    class Request
      # object_id => "$L<hex>" reference (dedup)
      attr_reader :written_objects
      attr_reader :bundler_config, :root_model, :strict_serialization, :on_as_json_warning, :development

      def initialize(model, bundler_config, strict_serialization: false, on_as_json_warning: nil,
                     development: false)
        @strict_serialization = strict_serialization
        @on_as_json_warning   = on_as_json_warning
        @development          = development
        @suspense_symbol_ref  = nil
        @boundary_ref         = nil
        @next_chunk_id = 0
        @bundler_config = bundler_config

        @imports  = [] # I rows
        @rows     = [] # model and text rows other than the root
        @deferred = [] # { id:, element:, delay: }, in the order they were met
        @next_deferred = 0

        @written_objects = {}.compare_by_identity

        # Root task is always ID 0
        @root_model = model
      end

      def allocate_id
        id = @next_chunk_id
        @next_chunk_id += 1
        id
      end

      # An import row. Imports are handed out before any model row taken with them.
      def add_import(row)
        @imports << row
      end

      # A model or text row that a later row references.
      def add_row(row)
        @rows << row
      end

      # The rows written since the last call: imports first, then the rest, in
      # the order they were written. Whatever references them comes after.
      def take_rows
        taken = @imports + @rows
        @imports.clear
        @rows.clear
        taken
      end

      # Defers Suspense content: its row is rendered by {Renderer} after the
      # shell. Returns the id the row will have.
      def defer(element, delay)
        id = allocate_id
        @deferred << { id: id, element: element, delay: delay }
        id
      end

      # Whether deferred content is still to be rendered (content deferred while
      # rendering a deferred row counts too).
      def deferred?
        @next_deferred < @deferred.length
      end

      # The next deferred content, in the order it was met.
      def next_deferred
        deferred = @deferred[@next_deferred]
        @next_deferred += 1
        deferred
      end

      # The `"$<hex>"` reference to this response's `"$Sreact.suspense"` symbol
      # row, emitted once, before the first row that uses it.
      def suspense_symbol_ref
        @suspense_symbol_ref ||= begin
          id = allocate_id
          add_row(RowEmitter.model(id, JSON.generate("$Sreact.suspense")))
          "$#{id.to_s(16)}"
        end
      end

      # The runtime's own client component that catches an error in a Suspense
      # child (runtime/suspense-boundary.js). Not in the app's manifest: the
      # runtime registers it under this id.
      BOUNDARY_METADATA = ["ruact:boundary", [], "SuspenseBoundary"].freeze

      # The `"$L<hex>"` reference to {BOUNDARY_METADATA}'s import row, emitted
      # once per response.
      def boundary_ref
        @boundary_ref ||= begin
          id = allocate_id
          add_import(RowEmitter.import(id, JSON.generate(BOUNDARY_METADATA)))
          "$L#{id.to_s(16)}"
        end
      end
    end
  end
end
