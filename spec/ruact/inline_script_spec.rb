# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ruact::InlineScript do
  it "writes a JSON string that no byte of the payload can end the script with" do
    literal = described_class.string_literal(%(1:"</SCRIPT><!-- &   "))
    expect(literal).not_to match(/[<>&  ]/)
    expect(JSON.parse(literal)).to eq(%(1:"</SCRIPT><!-- &   "))
  end

  it "reads a binary-tagged UTF-8 payload as UTF-8" do
    literal = described_class.string_literal(+"ação".force_encoding(Encoding::BINARY))
    expect(JSON.parse(literal)).to eq("ação")
  end
end
