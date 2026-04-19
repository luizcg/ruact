# frozen_string_literal: true

require "spec_helper"

module Ruact
  module Flight
    RSpec.describe Renderer do
      let(:empty_manifest) { ClientManifest.from_hash({}) }
      let(:manifest_with_button) do
        ClientManifest.from_hash({
                                   "Button" => {
                                     "id" => "/assets/Button-abc.js",
                                     "name" => "Button",
                                     "chunks" => ["/assets/Button-abc.js"]
                                   }
                                 })
      end

      describe ".render" do
        it "renders ReactElement with no props to fixture" do
          element = ReactElement.new(type: "div")
          output  = described_class.render(element, empty_manifest)
          expect(output).to match_flight_fixture("react_element_no_props")
        end

        it "returns a String" do
          element = ReactElement.new(type: "span")
          expect(described_class.render(element, empty_manifest)).to be_a(String)
        end

        it "root row always has id 0" do
          element = ReactElement.new(type: "p")
          output  = described_class.render(element, empty_manifest)
          expect(output.lines.last).to start_with("0:")
        end
      end

      describe ".each" do
        it "yields rows when called with a block" do
          element = ReactElement.new(type: "div")
          rows    = []
          described_class.each(element, empty_manifest) { |row| rows << row }
          expect(rows).not_to be_empty
        end

        it "produces identical output to .render" do
          element  = ReactElement.new(type: "article")
          via_each = described_class.each(element, empty_manifest, streaming: false).to_a.join
          via_render = described_class.render(element, empty_manifest)
          expect(via_each).to eq(via_render)
        end

        it "returns Enumerator when called without block" do
          element = ReactElement.new(type: "div")
          result  = described_class.each(element, empty_manifest)
          expect(result).to be_an(Enumerator)
        end
      end

      describe "suspense timeout (Story 3.5 AC #4)" do
        let(:fallback)  { ReactElement.new(type: "span") }
        let(:inner)     { ReactElement.new(type: "div") }

        context "when deferred delay exceeds suspense_timeout (streaming: true)" do
          before do
            allow(Ruact.config).to receive(:suspense_timeout).and_return(1.0)
          end

          it "emits an E-type error row instead of the model row" do
            suspense = SuspenseElement.new(fallback: fallback, children: inner, delay: 5.0)
            rows = described_class.each(suspense, empty_manifest, streaming: true).to_a
            expect(rows).to include(a_string_matching(/:E/))
          end

          it "error row contains 'Suspense timeout exceeded'" do
            suspense = SuspenseElement.new(fallback: fallback, children: inner, delay: 5.0)
            rows = described_class.each(suspense, empty_manifest, streaming: true).to_a
            error_row = rows.find { |r| r.include?(":E") }
            expect(error_row).to include("Suspense timeout exceeded")
          end

          it "does NOT emit a plain model row for the timed-out chunk" do
            suspense = SuspenseElement.new(fallback: fallback, children: inner, delay: 5.0)
            rows = described_class.each(suspense, empty_manifest, streaming: true).to_a
            # Only root (0:) and the error row (1:E...) should exist — no bare model for deferred id
            unexpected = rows.reject { |r| r.start_with?("0:") || r.include?(":E") }
            expect(unexpected).to be_empty
          end
        end

        context "when deferred delay is within suspense_timeout (streaming: true)" do
          before do
            allow(Ruact.config).to receive(:suspense_timeout).and_return(10.0)
          end

          it "emits a model row (not an error row) and no E row" do
            suspense = SuspenseElement.new(fallback: fallback, children: inner, delay: 0.0)
            rows = described_class.each(suspense, empty_manifest, streaming: true).to_a
            expect(rows).not_to include(a_string_matching(/:E/))
          end
        end
      end

      describe "import row ordering" do
        it "emits import rows before the root model row" do
          element = ReactElement.new(
            type: ClientReference.new(module_id: "/assets/Button-abc.js", export_name: "Button"),
            props: {}
          )
          output = described_class.render(element, manifest_with_button)
          lines  = output.lines.map(&:strip).reject(&:empty?)

          import_idx = lines.index { |l| l.include?(":I[") }
          root_idx   = lines.index { |l| l.start_with?("0:") }

          expect(import_idx).not_to be_nil
          expect(import_idx).to be < root_idx
        end
      end
    end
  end
end
