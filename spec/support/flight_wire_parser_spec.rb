# frozen_string_literal: true

require "spec_helper"
require_relative "flight_wire_parser"

module Ruact
  module Spec
    RSpec.describe FlightWireParser do
      describe ".parse" do
        it "parses a single model row" do
          rows = described_class.parse(%(0:{"className":"box"}\n))

          expect(rows).to eq([
                               {
                                 id: 0,
                                 class: :model,
                                 payload: { "className" => "box" },
                                 raw: %(0:{"className":"box"}\n)
                               }
                             ])
        end

        it "parses a single import row and decodes the hex id" do
          rows = described_class.parse(%(a:I["/L.jsx","L",["/L.jsx"]]\n))

          expect(rows.length).to eq(1)
          expect(rows.first).to include(
            id: 10,
            class: :import,
            payload: ["/L.jsx", "L", ["/L.jsx"]]
          )
        end

        it "parses a single error row" do
          rows = described_class.parse(%(2:E{"message":"boom"}\n))

          expect(rows.first).to include(
            id: 2,
            class: :error,
            payload: { "message" => "boom" }
          )
        end

        it "parses a hint row with no id" do
          rows = described_class.parse(%(:HL"/preload.js"\n))

          expect(rows.first).to include(
            id: nil,
            class: :hint,
            payload: ["L", "/preload.js"]
          )
        end

        it "parses a T row of exactly LARGE_TEXT_THRESHOLD bytes followed by a model row that references it" do
          large_text = "a" * 1024
          wire = "1:T#{1024.to_s(16)},#{large_text}0:\"$T1\"\n"

          rows = described_class.parse(wire)

          expect(rows.length).to eq(2)
          expect(rows[0]).to include(id: 1, class: :text, payload: large_text)
          expect(rows[1]).to include(id: 0, class: :model, payload: "$T1")
        end

        it "parses a mixed-row sequence preserving wire order" do
          wire = %(1:I["/L.jsx","L",["/L.jsx"]]\n0:["$","$L1",null,{}]\n)

          rows = described_class.parse(wire)

          expect(rows.map { |r| [r[:id], r[:class]] }).to eq([[1, :import], [0, :model]])
        end

        it "parses empty input as an empty array" do
          expect(described_class.parse("")).to eq([])
        end

        it "raises FlightWireParseError naming the byte offset on malformed JSON" do
          wire = %(0:{not-json}\n)

          expect { described_class.parse(wire) }
            .to raise_error(FlightWireParseError, /cannot parse row at offset \d+/)
        end

        it "raises FlightWireParseError when a T row is truncated" do
          wire = "0:T#{10.to_s(16)},abc" # claims 16 bytes but provides 3

          expect { described_class.parse(wire) }
            .to raise_error(FlightWireParseError, /cannot parse row at offset 0: T row truncated/)
        end
      end
    end
  end
end
