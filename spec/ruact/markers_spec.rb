# frozen_string_literal: true

require "spec_helper"

# What a template leaves for the converter, read back the way the converter
# reads it: the writing side and the reading side of {Ruact::Markers} agree.
RSpec.describe Ruact::Markers do
  def parse(html)
    Nokogiri::HTML::DocumentFragment.parse(html).children.first
  end

  it "reads back the token a component marker carries" do
    expect(described_class.comment_token(parse(described_class.component("__RUACT_3__")))).to eq("__RUACT_3__")
  end

  it "reads back the token a component-with-children wrapper carries" do
    node = parse("#{described_class.component_open('__RUACT_1__')}<p>x</p>#{described_class::WRAPPER_CLOSE}")
    expect(node.name).to eq(described_class::WRAPPER_TAG)
    expect(described_class.wrapper_token(node)).to eq("__RUACT_1__")
  end

  it "reads back a Suspense fallback with quotes and entities, and its delay" do
    open = described_class.suspense_open('Say "hi" &hellip;', "2.5")
    node = parse("#{open}<p>x</p>#{described_class::SUSPENSE_CLOSE}")
    expect(node.name).to eq(described_class::SUSPENSE_TAG)
    expect(described_class.suspense_fallback(node)).to eq('Say "hi" …')
    expect(described_class.suspense_delay(node)).to eq(2.5)
  end

  it "has no delay when the template gave none, or one that cannot be waited on" do
    expect(described_class.suspense_delay(parse(described_class.suspense_open("x", nil)))).to be_nil
    %w[soon 1e309].push("", " ").each do |delay|
      expect(described_class.suspense_delay(parse(described_class.suspense_open("x", delay)))).to be_nil, delay.inspect
    end
  end

  it "has an empty fallback when the wrapper carries none" do
    bare = parse("<#{described_class::SUSPENSE_TAG}>#{described_class::SUSPENSE_CLOSE}")
    expect(described_class.suspense_fallback(bare)).to eq("")
  end
end
