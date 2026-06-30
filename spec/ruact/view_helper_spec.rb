# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/string/output_safety"
require "active_support/string_inquirer"

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

    # Story 14.2 (FR104) — the public JS-asset helper. Emits the dev/prod
    # bootstrap entry `<script>` tags (re-targeting `virtual:ruact/bootstrap`)
    # plus the `__FLIGHT_DATA` inline script. The controller delegates to this
    # one implementation (parity asserted in controller_spec).
    describe "#ruact_js_assets", :story_14_2 do
      let(:asset_helper) do
        obj = Object.new
        obj.extend(described_class)
        obj
      end
      let(:payload) { "0:[\"$\",\"div\",null,{}]\n" }

      context "when in dev with the Vite dev server running" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
          allow(asset_helper).to receive(:vite_dev_running?).and_return(true)
        end

        it "emits the react-refresh preamble, @vite/client, and the bootstrap module", :aggregate_failures do
          html = asset_helper.ruact_js_assets(payload)
          expect(html).to include("__vite_plugin_react_preamble_installed__")
          expect(html).to include("http://localhost:5173/@vite/client")
          # Targets the virtual entry at the dev server's /@id/__x00__ URL — NOT
          # a stale application.jsx path.
          expect(html).to include("/@id/__x00__#{Ruact.bootstrap_virtual_id}")
          expect(html).not_to include("application.jsx")
        end

        it "includes the __FLIGHT_DATA inline bootstrap script", :aggregate_failures do
          html = asset_helper.ruact_js_assets(payload)
          expect(html).to include("__FLIGHT_DATA")
          expect(html).to include("d.push(")
        end

        it "returns an html_safe buffer" do
          expect(asset_helper.ruact_js_assets(payload)).to be_html_safe
        end
      end

      context "when in prod (Vite manifest lookup)" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        end

        it "looks up the manifest with the SAME id the generated vite.config input uses (AC3 — no drift)" do
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
          asset_helper.ruact_js_assets(payload)
          expect(asset_helper).to have_received(:vite_manifest_entry).with(Ruact.bootstrap_virtual_id)
        end

        it "emits the hashed bootstrap URL from the manifest entry", :aggregate_failures do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .with(Ruact.bootstrap_virtual_id).and_return({ "file" => "bootstrap-abc123.js" })
          html = asset_helper.ruact_js_assets(payload)
          expect(html).to include(%(src="/assets/bootstrap-abc123.js"))
          expect(html).to include("__FLIGHT_DATA")
        end

        it "falls back to /assets/application.js when the manifest entry is missing" do
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
          expect(asset_helper.ruact_js_assets(payload)).to include("/assets/application.js")
        end
      end

      context "without a Flight payload (entry tags only)" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
        end

        it "emits only the entry tag (no __FLIGHT_DATA)", :aggregate_failures do
          html = asset_helper.ruact_js_assets
          expect(html).not_to include("__FLIGHT_DATA")
          expect(html).to include("<script type=\"module\"")
        end
      end
    end
  end
end
