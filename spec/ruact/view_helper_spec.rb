# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/string/output_safety"

module Ruact
  RSpec.describe ViewHelper do
    let(:helper_obj) do
      obj = Object.new
      obj.extend(described_class)
      obj
    end

    before { ComponentRegistry.start }
    after  { ComponentRegistry.reset }

    describe "#__rsc_component__" do
      it "registers the component in ComponentRegistry and returns an HTML comment" do
        result = helper_obj.__rsc_component__("NavBar", { "currentUser" => 1 })
        expect(result).to match(/<!-- __RSC_\d+__ -->/)
        expect(ComponentRegistry.components.length).to eq(1)
        expect(ComponentRegistry.components.first[:name]).to eq("NavBar")
        expect(ComponentRegistry.components.first[:props]).to eq({ "currentUser" => 1 })
      end

      it "returns an html_safe string so ActionView does not escape the comment" do
        result = helper_obj.__rsc_component__("Button", {})
        expect(result).to be_html_safe
      end

      it "uses incrementing token numbers for successive registrations" do
        token0 = helper_obj.__rsc_component__("Foo", {})
        token1 = helper_obj.__rsc_component__("Bar", {})
        expect(token0).to include("__RSC_0__")
        expect(token1).to include("__RSC_1__")
      end

      it "passes props through to the registry entry" do
        helper_obj.__rsc_component__("LikeButton", { "postId" => 42, "label" => "Like" })
        entry = ComponentRegistry.components.first
        expect(entry[:props]["postId"]).to eq(42)
        expect(entry[:props]["label"]).to eq("Like")
      end
    end
  end
end
