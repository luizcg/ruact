# frozen_string_literal: true

require "strscan"
require "json"

module Ruact
  # Test-support utilities. Code under `Ruact::Spec` is consumed only by the
  # gem's own RSpec suite; it is not part of the public API and may change
  # shape across stories without a deprecation cycle.
  module Spec
    # Raised when {FlightWireParser.parse} encounters input it cannot decode.
    # The message names the byte offset of the unparseable row so the spec
    # author can locate the problem in a printed wire string.
    class FlightWireParseError < StandardError; end

    # Parses a Flight wire byte string into an ordered array of row records.
    #
    # Used by the structural Flight RSpec matchers
    # (`match_flight_structure` / `include_flight_row`) to assert on parsed
    # semantics rather than literal bytes. Pure function — no I/O, no global
    # state, no `Thread.current`.
    #
    # @example
    #   wire = "1:I[\"/L.jsx\",\"L\",[\"/L.jsx\"]]\n0:[\"$\",\"$L1\",null,{}]\n"
    #   Ruact::Spec::FlightWireParser.parse(wire)
    #   # => [
    #   #      { id: 1, class: :import, payload: ["/L.jsx", "L", ["/L.jsx"]], raw: "1:I...\n" },
    #   #      { id: 0, class: :model,  payload: ["$", "$L1", nil, {}],       raw: "0:[\"$\"...\n" }
    #   #    ]
    class FlightWireParser
      # Parse a complete Flight wire byte string.
      #
      # @param wire [String] the raw bytes emitted by `Ruact::Flight::Renderer`.
      # @return [Array<Hash>] one hash per row, in wire order. See class docs
      #   for the hash shape (`:id`, `:class`, `:payload`, `:raw`).
      # @raise [Ruact::Spec::FlightWireParseError] when a row is malformed.
      def self.parse(wire)
        rows = []
        scanner = StringScanner.new(wire)

        until scanner.eos?
          start_offset = scanner.pos
          rows << parse_row(scanner, start_offset)
        end

        rows
      end

      def self.parse_row(scanner, start_offset)
        # Hint rows have no ID: ":H<code><json>\n"
        if scanner.peek(2) == ":H"
          scanner.pos += 2
          code = scanner.getch
          raise_parse_error(start_offset, "missing hint code char") if code.nil?

          json = read_to_newline(scanner, start_offset)
          return {
            id: nil,
            class: :hint,
            payload: [code, parse_json(json, start_offset)],
            raw: scanner.string.byteslice(start_offset, scanner.pos - start_offset)
          }
        end

        hex = scanner.scan(/\h+/) || raise_parse_error(start_offset, "expected hex id")
        scanner.skip(":") || raise_parse_error(start_offset, "expected ':' after id")
        id = hex.to_i(16)

        case scanner.peek(1)
        when "I" then parse_tagged(:import, scanner, id, start_offset)
        when "T" then parse_text_row(scanner, id, start_offset)
        when "E" then parse_tagged(:error, scanner, id, start_offset)
        else          parse_model_row(scanner, id, start_offset)
        end
      end

      def self.parse_tagged(klass, scanner, id, start_offset)
        scanner.getch # consume the tag byte (I or E)
        json = read_to_newline(scanner, start_offset)
        {
          id: id,
          class: klass,
          payload: parse_json(json, start_offset),
          raw: scanner.string.byteslice(start_offset, scanner.pos - start_offset)
        }
      end

      def self.parse_model_row(scanner, id, start_offset)
        json = read_to_newline(scanner, start_offset)
        {
          id: id,
          class: :model,
          payload: parse_json(json, start_offset),
          raw: scanner.string.byteslice(start_offset, scanner.pos - start_offset)
        }
      end

      def self.parse_text_row(scanner, id, start_offset)
        scanner.getch # consume "T"
        len_hex = scanner.scan(/\h+/) || raise_parse_error(start_offset, "expected hex length after T")
        scanner.skip(",") || raise_parse_error(start_offset, "expected ',' after T<len>")
        len = len_hex.to_i(16)

        text = scanner.peek(len)
        raise_parse_error(start_offset, "T row truncated") if text.nil? || text.bytesize < len

        scanner.pos += len
        {
          id: id,
          class: :text,
          payload: text,
          raw: scanner.string.byteslice(start_offset, scanner.pos - start_offset)
        }
      end

      def self.read_to_newline(scanner, start_offset)
        line = scanner.scan_until(/\n/) || raise_parse_error(start_offset, "missing trailing newline")
        line.chomp
      end

      def self.parse_json(str, offset)
        JSON.parse(str)
      rescue JSON::ParserError => e
        raise_parse_error(offset, "invalid JSON: #{e.message}")
      end

      def self.raise_parse_error(offset, reason)
        raise FlightWireParseError, "FlightWireParser: cannot parse row at offset #{offset}: #{reason}"
      end

      private_class_method :parse_row, :parse_tagged, :parse_model_row, :parse_text_row,
                           :read_to_newline, :parse_json, :raise_parse_error
    end
  end
end
