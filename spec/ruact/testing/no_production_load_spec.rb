# frozen_string_literal: true

require "spec_helper"
require "English"
require "shellwords"

# Story 15.4 (FR108), AC4c + AC2 — the public test surface must not load in a
# production boot, and the promoted parser/diff must be the SINGLE shipped
# implementation the internal `Ruact::Spec` matchers share (wrap, not fork).
module Ruact
  RSpec.describe "Ruact::Testing load boundary", :story_15_4 do
    it "a bare `require \"ruact\"` does NOT define the public test surface" do
      # Shell out to a pristine Ruby process so nothing this suite already
      # loaded (spec/support requires `ruact/testing/*`) pollutes the check.
      lib = File.expand_path("../../../lib", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{lib.inspect})
        require "ruact"
        defined = Ruact.const_defined?(:Testing, false)
        # `have_ruact_component` must not be registered on the RSpec matcher surface either.
        rspec_loaded = $LOADED_FEATURES.any? { |f| f.include?("rspec/expectations") }
        print [defined, rspec_loaded].inspect
      RUBY

      output = `#{RbConfig.ruby} -e #{Shellwords.escape(script)} 2>&1`
      expect($CHILD_STATUS).to be_success, "subprocess failed: #{output}"
      expect(output).to eq("[false, false]"),
                        "expected `require \"ruact\"` to leave Ruact::Testing undefined and " \
                        "RSpec unloaded, got: #{output}"
    end

    it "shares ONE implementation with the internal matchers (no fork)" do
      require "ruact/testing"
      require_relative "../../support/flight_wire_parser"
      require_relative "../../support/matchers/flight_fixture_matcher"

      expect(Ruact::Spec::FlightWireParser).to equal(Ruact::Testing::FlightWireParser)
      expect(Ruact::Spec::FlightStructureDiff).to equal(Ruact::Testing::FlightStructureDiff)
    end
  end
end
