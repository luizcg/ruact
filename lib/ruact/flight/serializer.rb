# frozen_string_literal: true

require "json"
require "date"

module Ruact
  module Flight
    # Converts a Ruby value/element tree into Flight wire format rows.
    # All methods return the *inline* representation of the value
    # (what goes inside a parent row). Side effects go into request queues.
    class Serializer
      # Strings larger than this are outlined into their own T row.
      LARGE_TEXT_THRESHOLD = 1024

      def initialize(request)
        @request = request
      end

      # Entry point. Returns a value safe to pass to JSON.generate.
      def serialize_model(value)
        case value
        when NilClass
          nil
        when TrueClass, FalseClass
          value
        when Integer
          serialize_integer(value)
        when Float
          serialize_float(value)
        when String
          serialize_string(value)
        when Symbol
          serialize_symbol(value)
        when Time, DateTime
          serialize_date(value)
        when ClientReference
          serialize_client_reference(value)
        when SuspenseElement
          serialize_suspense(value)
        when ReactElement
          serialize_element(value)
        when Array
          serialize_array(value)
        when Hash
          serialize_hash(value)
        else
          serialize_unknown(value)
        end
      end

      private

      # --- Primitives ---

      def serialize_string(value)
        # Large strings get their own T row
        if value.bytesize >= LARGE_TEXT_THRESHOLD
          id = @request.allocate_id
          @request.increment_pending
          row = RowEmitter.text(id, value)
          @request.completed_regular_chunks << row
          return "$T#{id.to_s(16)}"
        end

        # Escape leading $ so the client doesn't misinterpret it.
        # "$danger" → "$$danger" (prepend one extra $, not two)
        value.start_with?("$") ? "$#{value}" : value
      end

      def serialize_integer(value)
        # BigInt range check (JS safe integer: ±2^53 - 1)
        if value.abs > 9_007_199_254_740_991
          "$n#{value}"
        else
          value
        end
      end

      def serialize_float(value)
        return "$NaN"       if value.nan?
        return "$Infinity"  if value.infinite? == 1
        return "$-Infinity" if value.infinite? == -1
        return "$-0"        if value.zero? && (1.0 / value).infinite? == -1

        value
      end

      def serialize_symbol(value)
        # Only :undefined is special for now
        return "$undefined" if value == :undefined

        # Unknown symbols: just use the name as a string
        value.to_s
      end

      def serialize_date(value)
        "$D#{value.iso8601(3)}"
      end

      # --- Collections ---

      def serialize_array(value)
        value.map { |v| serialize_model(v) }
      end

      def serialize_hash(value)
        value.transform_keys(&:to_s).transform_values { |v| serialize_model(v) }
      end

      # --- React Element ---

      def serialize_element(element)
        type = element.type

        resolved_type = case type
                        when String
                          # DOM element ("div", "span", etc.) — pass through as-is
                          type
                        when ClientReference
                          serialize_client_reference(type)
                        else
                          raise TypeError, "Unsupported element type: #{type.inspect}"
                        end

        key   = element.key
        props = serialize_hash(element.props)

        ["$", resolved_type, key, props]
      end

      # --- Suspense Boundary ---

      def serialize_suspense(element)
        # Allocate ID for the deferred content row (emitted after root row + delay)
        deferred_id = @request.allocate_id
        @request.deferred_chunks << { id: deferred_id, element: element.children, delay: element.delay }

        fallback_value = element.fallback ? serialize_model(element.fallback) : nil

        # Children is an element tuple using the lazy ref as its type
        lazy_ref = "$L#{deferred_id.to_s(16)}"
        children_el = ["$", lazy_ref, nil, {}]

        ["$", "$SS", nil, { "fallback" => fallback_value, "children" => children_el }]
      end

      # --- Unknown type fallback ---

      def serialize_unknown(value)
        return serialize_serializable(value) if value.is_a?(Ruact::Serializable)

        if value.respond_to?(:as_json)
          if @request.strict_serialization
            raise Ruact::SerializationError,
                  "Cannot serialize #{value.class.name} — " \
                  "include Ruact::Serializable or set strict_serialization: false"
          else
            serialize_as_json(value)
          end
        else
          raise Ruact::SerializationError,
                "Cannot serialize #{value.class.name} — include Ruact::Serializable"
        end
      end

      # --- Serializable (explicit opt-in, no warning) ---

      def serialize_serializable(value)
        serialize_model(value.rsc_serialize)
      end

      # --- as_json fallback (strict_serialization: false only) ---

      def serialize_as_json(value)
        data = begin
          value.as_json
        rescue StandardError => e
          raise Ruact::SerializationError,
                "#{value.class.name}#as_json raised #{e.class}: #{e.message}"
        end

        if data.equal?(value)
          raise Ruact::SerializationError,
                "#{value.class.name}#as_json returned self — would cause infinite recursion. " \
                "Include Ruact::Serializable and declare rsc_props instead"
        end

        attr_names = data.is_a?(Hash) ? data.keys.join(", ") : ""
        @request.on_as_json_warning&.call(value.class.name, attr_names)
        serialize_model(data)
      end

      # --- Client Reference ---

      def serialize_client_reference(ref)
        # Deduplication: same object → same $L reference
        existing = @request.written_objects[ref]
        return existing if existing

        metadata = @request.bundler_config.resolve(ref.module_id, ref.export_name)

        id = @request.allocate_id
        @request.increment_pending

        json = JSON.generate(metadata)
        row  = RowEmitter.import(id, json)
        @request.completed_import_chunks << row

        lazy_ref = "$L#{id.to_s(16)}"
        @request.written_objects[ref] = lazy_ref
        lazy_ref
      end
    end
  end
end
