# frozen_string_literal: true

require "spec_helper"

# Specs for the three Flight wire matcher modes added in Story 7.5
# (`match_flight_fixture`, `match_flight_structure`, `include_flight_row`).
RSpec.describe "Flight wire matchers" do
  # Captures an `ExpectationNotMetError` raised by the inner block so the
  # spec can make multiple assertions on its message without resorting to a
  # multi-line block chained off `raise_error`.
  def capture_failure
    yield
    nil
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e
  end

  describe "match_flight_fixture (existing snapshot mode)" do
    let(:nil_wire) { "0:null\n" }

    it "passes against canonical fixture content (regression check)" do
      expect(nil_wire).to match_flight_fixture("nil")
    end
  end

  describe "match_flight_structure" do
    let(:simple_wire) { %(0:{"className":"box"}\n) }
    let(:two_row_wire) { %(1:I["/L.jsx","L",["/L.jsx"]]\n0:["$","$L1",null,{}]\n) }

    it "passes when the actual wire matches a single-row expected structure" do
      expect(simple_wire).to match_flight_structure([
                                                      { id: 0, class: :model, payload: { "className" => "box" } }
                                                    ])
    end

    it "passes for a two-row mixed import + model sequence" do
      expect(two_row_wire).to match_flight_structure([
                                                       { id: 1, class: :import, payload: ["/L.jsx", "L", ["/L.jsx"]] },
                                                       { id: 0, class: :model, payload: ["$", "$L1", nil, {}] }
                                                     ])
    end

    it "fails with a missing-row message when actual has fewer rows than expected" do
      err = capture_failure do
        expect(simple_wire).to match_flight_structure([
                                                        { id: 0, class: :model, payload: { "className" => "box" } },
                                                        { id: 1, class: :import, payload: [] }
                                                      ])
      end

      expect(err.message).to include("Expected row 1 (import) was not produced.")
      expect(err.message).to include("expected: {")
    end

    it "produces the AC3 verbatim row-indexed diff for a single-field semantic regression" do
      broken_wire = %(0:["$X","div",null,{"className":"box","children":"hi"}]\n)
      expected_structure = [
        { id: 0, class: :model,
          payload: ["$", "div", nil, { "className" => "box", "children" => "hi" }] }
      ]

      expected_message = <<~MSG.strip
        Expected Flight output to match structure.

        Row 0 (model) differs at .payload[0]:
          expected: "$"
          got:      "$X"

        Row 0 (model) full diff:
          expected: ["$", "div", nil, {"className" => "box", "children" => "hi"}]
          got:      ["$X", "div", nil, {"className" => "box", "children" => "hi"}]
      MSG

      expect do
        expect(broken_wire).to match_flight_structure(expected_structure)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, expected_message)
    end

    it "fails with an unexpected-row message when actual has extra rows" do
      err = capture_failure do
        expect(two_row_wire).to match_flight_structure([
                                                         { id: 1, class: :import,
                                                           payload: ["/L.jsx", "L", ["/L.jsx"]] }
                                                       ])
      end

      expect(err.message).to include("Got unexpected row 1 (model)")
    end

    it "tolerates cosmetic JSON key reordering in payload hashes (AC4)" do
      canonical = %(0:{"a":1,"b":2}\n)
      perturbed = %(0:{"b":2,"a":1}\n)
      expected_structure = [{ id: 0, class: :model, payload: { "a" => 1, "b" => 2 } }]

      expect(canonical).to match_flight_structure(expected_structure)
      expect(perturbed).to match_flight_structure(expected_structure)
    end

    it "passes negation when the structure does not match" do
      expect(simple_wire).not_to match_flight_structure([
                                                          { id: 0, class: :model, payload: { "className" => "circle" } }
                                                        ])
    end

    # AC1: "multiple I rows are an unordered set". The expected list below
    # reverses the import order vs the wire — the structural matcher must
    # still consider this a match because import-row ordering is not
    # protocol-significant within the import class.
    it "treats import rows as an unordered set (AC1)" do
      wire = %(1:I["/A.jsx","A",["/A.jsx"]]\n2:I["/B.jsx","B",["/B.jsx"]]\n0:["$","$L1",null,{}]\n)

      expect(wire).to match_flight_structure([
                                               { id: 2, class: :import, payload: ["/B.jsx", "B", ["/B.jsx"]] },
                                               { id: 1, class: :import, payload: ["/A.jsx", "A", ["/A.jsx"]] },
                                               { id: 0, class: :model, payload: ["$", "$L1", nil, {}] }
                                             ])
    end

    # Defends against incomplete expected rows silently passing when actual
    # payload happens to be nil (e.g. `{ id: 0, class: :model }` without
    # `:payload` would otherwise satisfy any row whose payload is nil).
    it "raises ArgumentError when an expected row is missing :payload" do
      expect do
        expect(simple_wire).to match_flight_structure([{ id: 0, class: :model }])
      end.to raise_error(ArgumentError, /missing required keys.*:payload/)
    end

    it "raises ArgumentError when an expected row is missing :class" do
      expect do
        expect(simple_wire).to match_flight_structure([{ id: 0, payload: {} }])
      end.to raise_error(ArgumentError, /missing required keys.*:class/)
    end

    # Multi-row failure message: the count, AC3 wording for missing/extra,
    # plus a "✓" line for every matching row so the reader can confirm
    # which rows passed (AC3 — "Other rows that match are summarized as
    # `Row N (<class>): ✓`").
    it "shows matching-row checkmarks alongside multi-row diffs" do
      wire = %(1:I["/A.jsx","A",["/A.jsx"]]\n0:["$X","div",null,{}]\n)

      err = capture_failure do
        expect(wire).to match_flight_structure([
                                                 { id: 1, class: :import, payload: ["/A.jsx", "A", ["/A.jsx"]] },
                                                 { id: 0, class: :model, payload: ["$", "div", nil, {}] },
                                                 { id: 2, class: :model, payload: ["$", "span", nil, {}] }
                                               ])
      end

      expect(err.message).to include("Expected Flight output to match structure. 2 rows differ:")
      expect(err.message).to include("Row 0 (import): ✓")
      expect(err.message).to include("Row 1 (model) differs at .payload[0]:")
      expect(err.message).to include("Expected row 2 (model) was not produced.")
    end
  end

  describe "include_flight_row" do
    let(:wire_with_post_id) do
      %(1:I["/L.jsx","L",["/L.jsx"]]\n0:["$","$L1",null,{"postId":42}]\n)
    end

    it "matches when at least one row satisfies a hash_including payload predicate" do
      expect(wire_with_post_id).to include_flight_row(
        class: :model,
        payload: include("postId" => 42)
      )
    end

    it "fails listing parsed rows when no row matches the predicate" do
      err = capture_failure do
        expect(wire_with_post_id).to include_flight_row(
          class: :model,
          payload: include("postId" => 999)
        )
      end

      expect(err.message).to include("Expected Flight output to include a row matching")
      expect(err.message).to include("[0] id=1, class=import")
      expect(err.message).to include("[1] id=0, class=model")
    end

    it "supports negation with not_to" do
      expect(wire_with_post_id).not_to include_flight_row(class: :error)
    end

    it "fails negation when a row matches, naming the offending row index" do
      expect do
        expect(wire_with_post_id).not_to include_flight_row(class: :import)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /but row 0 matched/)
    end

    it "supports array_including for the payload key" do
      expect(wire_with_post_id).to include_flight_row(
        class: :import,
        payload: include("/L.jsx")
      )
    end

    # AC4 fixture-mode failure proof. The structural matcher tolerates the
    # cosmetic perturbation; the fixture matcher fails *positively* with the
    # expected-vs-got diff visible — confirming fixture mode is the wire-
    # format contract guard. This spec verifies the failure message rather
    # than relying on a `not_to` shortcut (which would prove only that the
    # matcher returned false, not that the failure is loud and informative).
    it "demonstrates cosmetic-vs-fixture asymmetry — structure tolerates re-ordering, fixture fails loudly (AC4)" do
      canonical_wire = %(0:{"debug":true,"count":5,"label":"x"}\n)
      perturbed_wire = %(0:{"label":"x","count":5,"debug":true}\n)
      expected_structure = [
        { id: 0, class: :model, payload: { "debug" => true, "count" => 5, "label" => "x" } }
      ]

      err = capture_failure do
        expect(perturbed_wire).to match_flight_fixture("hash")
      end

      aggregate_failures do
        # Structural mode: both pass — JSON key reordering is cosmetic.
        expect(canonical_wire).to match_flight_structure(expected_structure)
        expect(perturbed_wire).to match_flight_structure(expected_structure)

        # Fixture mode: canonical passes — the fixture file is the canonical
        # wire bytes.
        expect(canonical_wire).to match_flight_fixture("hash")

        # Fixture mode against the perturbed wire fails *loudly* with the
        # bytes-for-bytes diff so a human reviewer can see the cosmetic drift.
        expect(err).to be_a(RSpec::Expectations::ExpectationNotMetError)
        expect(err.message).to include("Expected output to match fixture at", "hash.txt", "Expected:", "Got:")
        expect(err.message).to include(perturbed_wire.inspect)
      end
    end

    # Predicate validation: an unknown key (typo) must raise immediately.
    # Otherwise `row[:payloed]` returns nil and `nil == nil` would silently
    # match every row, hiding broken specs.
    it "raises ArgumentError when the predicate has an unknown key" do
      expect do
        expect(wire_with_post_id).to include_flight_row(payloed: { "postId" => 42 })
      end.to raise_error(ArgumentError, /unknown keys.*:payloed/)
    end

    it "raises ArgumentError when given an empty predicate" do
      expect do
        expect(wire_with_post_id).to include_flight_row({})
      end.to raise_error(ArgumentError, /predicate cannot be empty/)
    end
  end
end
