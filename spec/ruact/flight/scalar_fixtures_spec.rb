# frozen_string_literal: true

require "spec_helper"
require "json"
require "active_support/core_ext/time"

# Story 17-0c — dates and integers beyond JS's safe range reach React as `Date`
# and `BigInt`. The JS tests decode what the Ruby serializer actually emits;
# this spec writes that payload and guards it against drift, plus the values
# the client must rebuild (as ISO strings / decimal strings, since JSON has no
# Date or BigInt). Regenerate with RUACT_WRITE_FIXTURES=1.
module ScalarFixtures
  DIR = File.expand_path("../../fixtures/flight", __dir__)

  def self.values
    {
      "time" => Time.utc(2026, 9, 8, 12, 30, 45, 123_456),
      "zoned" => Time.find_zone!("America/Sao_Paulo").local(2026, 9, 8, 9, 30),
      "datetime" => DateTime.new(2026, 9, 8, 1, 2, 3),
      "big" => (2**53) + 1,
      "negative_big" => -(2**64),
      "max_safe" => (2**53) - 1,
      "min_safe" => -((2**53) - 1),
      "literal" => "$D2026-01-01 is a string",
      "nested" => { "at" => [Time.utc(2000, 1, 1)], "ids" => [2**60, 7] }
    }
  end

  # What JS must rebuild: dates as their instant (ISO, UTC, milliseconds),
  # BigInts as decimal strings, everything else as is.
  EXPECTED = {
    "time" => { "date" => "2026-09-08T12:30:45.123Z" },
    "zoned" => { "date" => "2026-09-08T12:30:00.000Z" },
    "datetime" => { "date" => "2026-09-08T01:02:03.000Z" },
    "big" => { "bigint" => "9007199254740993" },
    "negative_big" => { "bigint" => "-18446744073709551616" },
    "max_safe" => 9_007_199_254_740_991,
    "min_safe" => -9_007_199_254_740_991,
    "literal" => "$D2026-01-01 is a string",
    "nested" => { "at" => [{ "date" => "2000-01-01T00:00:00.000Z" }],
                  "ids" => [{ "bigint" => "1152921504606846976" }, 7] }
  }.freeze
end

RSpec.describe "Flight scalar fixtures" do
  it "scalar_round_trip.txt matches what the serializer emits today" do
    path = File.join(ScalarFixtures::DIR, "scalar_round_trip.txt")
    wire = Ruact::Flight::Renderer.render(ScalarFixtures.values, Ruact::ClientManifest.from_hash({}))
    File.binwrite(path, wire) if ENV["RUACT_WRITE_FIXTURES"]
    expect(File.binread(path)).to eq(wire.b),
                                  "scalar_round_trip.txt drifted from the serializer. Regenerate: " \
                                  "RUACT_WRITE_FIXTURES=1 bundle exec rspec #{__FILE__}"
  end

  it "scalar_round_trip_expected.json holds what the client must rebuild" do
    path = File.join(ScalarFixtures::DIR, "scalar_round_trip_expected.json")
    json = "#{JSON.pretty_generate(ScalarFixtures::EXPECTED)}\n"
    File.write(path, json) if ENV["RUACT_WRITE_FIXTURES"]
    expect(File.read(path)).to eq(json)
  end
end
