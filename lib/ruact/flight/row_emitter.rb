# frozen_string_literal: true

module Ruact
  module Flight
    # Formats Flight wire format rows.
    #
    # Text rows:   <hex_id>:<tag><json_payload>\n
    # Binary rows: <hex_id>:<tag><hex_byte_length>,<binary_data>   (no newline)
    module RowEmitter
      # A plain model row (most elements, objects, arrays)
      def self.model(id, json)
        "#{id.to_s(16)}:#{json}\n"
      end

      # An import row — tells the client where to load a "use client" module
      def self.import(id, metadata_json)
        "#{id.to_s(16)}:I#{metadata_json}\n"
      end

      # An error row
      def self.error(id, error_json)
        "#{id.to_s(16)}:E#{error_json}\n"
      end

      # A large text row (binary framing, no trailing newline)
      def self.text(id, text)
        byte_length = text.bytesize
        "#{id.to_s(16)}:T#{byte_length.to_s(16)},#{text}"
      end

      # A hint row — no ID, fire-and-forget preload signal
      def self.hint(code, model_json)
        ":H#{code}#{model_json}\n"
      end
    end
  end
end
