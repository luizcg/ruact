# frozen_string_literal: true

require_relative "../flight_wire_parser"
require "ruact/testing/flight_structure_diff"

module Ruact
  module Spec
    # Story 15.4 (FR108) — the structural diff engine was PROMOTED onto the
    # gem's `lib/` load path as `Ruact::Testing::FlightStructureDiff` (shared,
    # single implementation — wrap, not fork). This test-only `Ruact::Spec`
    # alias keeps the internal matcher wrappers below and their self-tests
    # working unchanged.
    FlightStructureDiff = Ruact::Testing::FlightStructureDiff
  end
end

# `match_flight_fixture(name)` — Phase 1 byte-exact snapshot matcher.
#
# Reads `spec/fixtures/flight/<name>.txt` and compares the actual wire bytes
# to the file contents via `==`. Used when the wire format itself is the
# contract (escape rules, ordering invariants, payload framing).
#
# @example
#   expect(serializer.serialize_value("$danger")).to match_flight_fixture("string_dollar_escape")
RSpec::Matchers.define :match_flight_fixture do |name|
  match do |actual|
    fixtures_dir = File.expand_path("../../fixtures/flight", __dir__)
    fixture_path = File.join(fixtures_dir, "#{name}.txt")
    @fixture_path = fixture_path
    @expected = File.read(fixture_path)
    actual == @expected
  end

  failure_message do |actual|
    "Expected output to match fixture at #{@fixture_path}.\n\n" \
      "Expected:\n#{@expected.inspect}\n\n" \
      "Got:\n#{actual.inspect}"
  end

  failure_message_when_negated do |_actual|
    "Expected output NOT to match fixture at #{@fixture_path}, but it did."
  end

  description do
    "match Flight wire fixture '#{name}'"
  end
end

# `match_flight_structure(expected)` — Phase 2 structural matcher (Story 7.5).
#
# Parses the actual Flight wire output via `Ruact::Spec::FlightWireParser`,
# then compares the resulting array of row records against `expected`. Hash
# payloads are compared structurally (key insertion order is ignored), so
# cosmetic JSON re-ordering does not break specs that assert on semantics.
# Import rows are matched as a multiset; non-import rows are compared
# positionally because Flight semantics depend on their order.
#
# Failure messages name the row index and the differing field — bytes are
# only printed when no narrower diff is available.
#
# @example
#   expect(wire).to match_flight_structure([
#     { id: 1, class: :import, payload: ["/L.jsx", "L", ["/L.jsx"]] },
#     { id: 0, class: :model,  payload: ["$", "$L1", nil, {}] }
#   ])
RSpec::Matchers.define :match_flight_structure do |expected|
  match do |actual|
    @parsed = Ruact::Spec::FlightWireParser.parse(actual)
    @expected_rows = expected
    @diffs = Ruact::Spec::FlightStructureDiff.compute(@parsed, expected)
    @diffs.empty?
  end

  failure_message do |_actual|
    if @diffs.length == 1
      Ruact::Spec::FlightStructureDiff.format_single(@diffs.first)
    else
      Ruact::Spec::FlightStructureDiff.format_multi(@diffs, @parsed, @expected_rows)
    end
  end

  failure_message_when_negated do |_actual|
    "Expected output NOT to match the given Flight wire structure, but it did."
  end

  description do
    "match Flight wire structure (#{expected.length} row(s))"
  end
end

# `include_flight_row(predicate)` — Phase 2 ordering-independent presence matcher (Story 7.5).
#
# Parses the actual Flight wire output, then asserts at least one parsed row
# satisfies the predicate hash. Subset semantics: only the keys present in
# `predicate` are compared. Predicate keys must be one of `:id`, `:class`,
# `:payload`, `:raw` — unknown keys raise upfront so typos don't silently
# match every row. Values may be plain Ruby values (compared with `==`) or
# RSpec argument matchers like `hash_including(...)` (compared with `===`).
# Negation (`not_to`) is supported.
#
# @example
#   expect(wire).to include_flight_row(class: :model, payload: hash_including("postId" => 42))
RSpec::Matchers.define :include_flight_row do |predicate|
  match do |actual|
    Ruact::Spec::FlightStructureDiff.validate_predicate!(predicate)
    @parsed = Ruact::Spec::FlightWireParser.parse(actual)
    @predicate = predicate
    @matched_idx = @parsed.find_index { |row| Ruact::Spec::FlightStructureDiff.row_matches?(row, predicate) }
    !@matched_idx.nil?
  end

  failure_message do |_actual|
    summary = @parsed.each_with_index.map do |row, i|
      payload_snippet = row[:payload].inspect
      payload_snippet = "#{payload_snippet[0, 80]}…" if payload_snippet.length > 80
      "  [#{i}] id=#{row[:id].inspect}, class=#{row[:class]}, payload=#{payload_snippet}"
    end.join("\n")
    summary = "  (no rows parsed)" if @parsed.empty?

    "Expected Flight output to include a row matching: #{predicate.inspect}.\nParsed rows:\n#{summary}"
  end

  failure_message_when_negated do |_actual|
    "Expected Flight output NOT to include a row matching: #{predicate.inspect}, but row #{@matched_idx} matched."
  end

  description do
    "include a Flight row matching #{predicate.inspect}"
  end
end
