# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/string/output_safety"

module Ruact
  RSpec.describe ViewHelper do
    let(:render_context) { RenderContext.new }
    let(:helper_obj) do
      obj = Object.new
      obj.extend(described_class)
      obj.instance_variable_set(:@ruact_render_context, render_context)
      obj
    end

    describe "#__ruact_component__" do
      it "registers the component in the render context and returns an HTML comment" do
        result = helper_obj.__ruact_component__("NavBar", { "currentUser" => 1 })
        expect(result).to match(/<!-- __RUACT_\d+__ -->/)
        expect(render_context.components.length).to eq(1)
        expect(render_context.components.first[:name]).to eq("NavBar")
        expect(render_context.components.first[:props]).to eq({ "currentUser" => 1 })
      end

      it "returns an html_safe string so ActionView does not escape the comment" do
        result = helper_obj.__ruact_component__("Button", {})
        expect(result).to be_html_safe
      end

      it "uses incrementing token numbers for successive registrations" do
        token0 = helper_obj.__ruact_component__("Foo", {})
        token1 = helper_obj.__ruact_component__("Bar", {})
        expect(token0).to include("__RUACT_0__")
        expect(token1).to include("__RUACT_1__")
      end

      it "passes props through to the registry entry" do
        helper_obj.__ruact_component__("LikeButton", { "postId" => 42, "label" => "Like" })
        entry = render_context.components.first
        expect(entry[:props]["postId"]).to eq(42)
        expect(entry[:props]["label"]).to eq("Like")
      end

      it "raises a clear error when called outside a ruact_render flow" do
        bare = Object.new
        bare.extend(described_class)
        expect { bare.__ruact_component__("NavBar", {}) }
          .to raise_error(Ruact::Error, /__ruact_component__ called outside a ruact_render flow/)
      end
    end
  end
end
