# frozen_string_literal: true

require "spec_helper"
require "json"

# Story 17-0d — the JS decoder's text-framing tests consume payloads the Ruby
# serializer actually produced, not hand-written imitations. This spec writes
# those fixtures and guards them against drift: it renders the same values and
# compares byte for byte. Regenerate with RUACT_WRITE_FIXTURES=1.
module TextFramingFixtures
  DIR = File.expand_path("../../fixtures/flight", __dir__)

  # Strings either side of the 1024-byte threshold, and the content that
  # breaks naive framing: multibyte UTF-8 (byte length != string length),
  # embedded newlines, a leading `$`, and markup.
  VALUES = {
    "short" => "hello",
    "below" => "a" * 1023,
    "at" => "b" * 1024,
    "above" => "c" * 1025,
    "multibyte" => "ção é 😀 " * 120,
    "newlines" => "line one\nline two\n" * 80,
    "dollar" => "$#{'d' * 1100}",
    "markup" => "</script><b>bold</b> & more " * 60,
    "list" => ["x" * 1500, "short", "y" * 2048]
  }.freeze

  def self.render(file)
    manifest = Ruact::ClientManifest.from_hash({})
    case file
    when "text_framing.txt" then Ruact::Flight::Renderer.render(VALUES, manifest)
    when "text_framing_suspense.txt"
      inner = Ruact::Flight::ReactElement.new(type: "p", props: { "children" => VALUES["multibyte"] })
      suspense = Ruact::Flight::SuspenseElement.new(
        fallback: Ruact::Flight::ReactElement.new(type: "span"), children: inner, delay: 0.0
      )
      Ruact::Flight::Renderer.render(suspense, manifest)
    end
  end
end

RSpec.describe "Flight text-framing fixtures" do
  %w[text_framing.txt text_framing_suspense.txt].each do |file|
    it "#{file} matches what the serializer emits today" do
      path = File.join(TextFramingFixtures::DIR, file)
      wire = TextFramingFixtures.render(file)
      File.binwrite(path, wire) if ENV["RUACT_WRITE_FIXTURES"]
      expect(File.binread(path)).to eq(wire.b),
                                    "#{file} drifted from the serializer. Regenerate: " \
                                    "RUACT_WRITE_FIXTURES=1 bundle exec rspec #{__FILE__}"
    end
  end

  it "text_framing_expected.json holds the values the payload must decode to" do
    path = File.join(TextFramingFixtures::DIR, "text_framing_expected.json")
    json = "#{JSON.pretty_generate(TextFramingFixtures::VALUES)}\n"
    File.write(path, json) if ENV["RUACT_WRITE_FIXTURES"]
    expect(File.read(path)).to eq(json)
  end
end
