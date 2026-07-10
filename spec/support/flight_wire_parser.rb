# frozen_string_literal: true

# Story 15.4 (FR108) — the pure Flight wire parser was PROMOTED onto the gem's
# `lib/` load path as `Ruact::Testing::FlightWireParser` so the new public
# `have_ruact_component` matcher and the gem's own internal matchers share ONE
# implementation (wrap, not fork). This file is now a thin shim: it loads the
# promoted implementation and re-exports it under the historical test-only
# `Ruact::Spec` namespace so the existing internal matcher wrappers and their
# self-tests keep working unchanged.
require "ruact/testing/flight_wire_parser"

module Ruact
  # Test-support utilities. Code under `Ruact::Spec` is consumed only by the
  # gem's own RSpec suite; it is not part of the public API and may change
  # shape across stories without a deprecation cycle. The parser/diff it names
  # are aliases for the shipped `Ruact::Testing::*` implementation.
  module Spec
    FlightWireParser = Ruact::Testing::FlightWireParser
    FlightWireParseError = Ruact::Testing::FlightWireParseError
  end
end
