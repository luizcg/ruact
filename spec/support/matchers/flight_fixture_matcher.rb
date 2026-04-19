# frozen_string_literal: true

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
