# frozen_string_literal: true

require "rspec/expectations"

require_relative "testing/flight_wire_parser"
require_relative "testing/flight_structure_diff"
require_relative "testing/flight_extractor"
require_relative "testing/component_query"

# Public, host-app-facing render-assertion helpers (FR108, Story 15.4).
#
# Load this EXPLICITLY from your `spec_helper.rb`/`rails_helper.rb`:
#
#   require "ruact/testing"
#
# It is NOT auto-loaded by `require "ruact"` — a production boot never pulls in
# RSpec. Requiring this file registers the `have_ruact_component` RSpec matcher
# so request/controller specs can assert a page rendered a given component:
#
#   expect(response).to have_ruact_component("PostList")
#   expect(response).to have_ruact_component("PostList").with_props(including("posts"))
#   expect(response).not_to have_ruact_component("Admin")
#
# `response` may be an ActionDispatch/Rack response (its `.body` is read) or a
# raw String, in either page shape: a raw `text/x-component` body or an HTML
# shell embedding `__FLIGHT_DATA`. A `Ruact::Server` function-call/query answer
# is plain JSON, not Flight — passing it raises a clear error pointing you at
# `JSON.parse(response.body)` (see the "Testing" docs page).
#
# This is a STABLE public API (a conventional test matcher) — it wraps, and
# does not fork, the internal Story-7.5 structural parser/diff promoted to
# `Ruact::Testing::FlightWireParser` / `Ruact::Testing::FlightStructureDiff`.
module Ruact
  module Testing
    # Compares a rendered instance's serialized props against the value passed
    # to `.with_props`. A plain Hash requires exact equality (via `===`, i.e.
    # `==`); an RSpec argument matcher (`hash_including`, `including`, `a_hash_…`)
    # drives subset/fuzzy semantics through its own `#===`.
    def self.props_match?(expected, actual_props)
      # rubocop:disable Style/CaseEquality -- intentional: lets RSpec matchers (hash_including, …) drive semantics via #===.
      expected === actual_props
      # rubocop:enable Style/CaseEquality
    end
  end
end

# rubocop:disable Metrics/BlockLength -- a single cohesive RSpec matcher definition (match + chain + messages).
RSpec::Matchers.define :have_ruact_component do |name|
  match do |actual|
    @query = Ruact::Testing::ComponentQuery.new(Ruact::Testing::FlightExtractor.extract(actual))
    @instances_props = @query.props_for(name)
    next false if @instances_props.empty?
    next true unless defined?(@expected_props)

    @instances_props.any? { |props| Ruact::Testing.props_match?(@expected_props, props) }
  end

  chain :with_props do |expected|
    @expected_props = expected
  end

  failure_message do |_actual|
    if @instances_props && @instances_props.empty?
      rendered = @query.rendered_names
      found = rendered.empty? ? "no ruact components" : "components: #{rendered.inspect}"
      "expected the response to have rendered a ruact component named #{name.inspect}, " \
        "but found #{found}."
    else
      "expected a rendered #{name.inspect} to have props matching #{@expected_props.inspect}, " \
        "but none did. Rendered instance props (serialized wire form):\n" \
        "#{@instances_props.map(&:inspect).join("\n")}"
    end
  end

  failure_message_when_negated do |_actual|
    if defined?(@expected_props)
      "expected the response NOT to have a #{name.inspect} with props matching " \
        "#{@expected_props.inspect}, but one did."
    else
      "expected the response NOT to have rendered a ruact component named #{name.inspect}, " \
        "but it did."
    end
  end

  description do
    base = "have ruact component #{name.inspect}"
    defined?(@expected_props) ? "#{base} with props #{@expected_props.inspect}" : base
  end
end
# rubocop:enable Metrics/BlockLength
