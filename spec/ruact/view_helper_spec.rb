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

      # Story 17.0i review R1 — the innermost template can be a partial or a
      # layout: rendering THAT as the page is not the fix.
      it "points at the page, not the partial or layout, holding the component", :aggregate_failures do
        %w[posts/_form layouts/application].each do |path|
          bare = Object.new
          bare.extend(described_class)
          bare.instance_variable_set(:@current_template, Struct.new(:virtual_path).new(path))

          message = begin
            bare.__ruact_component__("NavBar", {})
          rescue Ruact::Error => e
            e.message
          end

          expect(message).to include("\"#{path}\"")
          expect(message).not_to include("ruact_render(template: \"#{path}\"")
          expect(message).to include("the page that renders it")
        end
      end

      # Review R2 — in a mailer's view, `controller` is the mailer: not a page a
      # concern would fix.
      it "does not tell a mailer to include the concern", :aggregate_failures do
        mailer = Struct.new(:name).new("UserMailer")
        bare = Object.new
        bare.extend(described_class)
        bare.define_singleton_method(:controller) { mailer }
        message = begin
          bare.__ruact_component__("NavBar", {})
        rescue Ruact::Error => e
          e.message
        end

        expect(message).not_to include("include Ruact::Controller`")
        expect(message).to include("only in a page a ruact controller renders")
      end

      it "raises a clear error when called outside a ruact_render flow" do
        bare = Object.new
        bare.extend(described_class)
        expect { bare.__ruact_component__("NavBar", {}) }
          .to raise_error(Ruact::Error, %r{<NavBar /> is a client component.*outside ruact.*ruact_render\(template: }m)
      end
    end

    # Story 14.2 (FR104) — the public JS-asset helper. Emits the dev/prod
    # bootstrap entry `<script>` tags (re-targeting `virtual:ruact/bootstrap`)
    # plus the `__FLIGHT_DATA` inline script. The controller delegates to this
    # one implementation (parity asserted in controller_spec).
    # Story 17.0b (issue #63) — the CSS half of the asset contract.
    #
    # Vite emits client-component CSS as a separate asset and records it on the
    # entry; `ruact_js_assets` only ever read `file`, so the stylesheet was built,
    # digest-stamped, served — and never referenced. Dev hid it, because the dev
    # server injects CSS through JS.
    #
    # This helper is deliberately SEPARATE from `ruact_js_assets` and belongs in
    # `<head>`: the JS helper is injected before `</body>`, and a stylesheet there
    # means FOUC plus a cascade in which third-party CSS outranks the app's own.
    describe "#ruact_head_assets", :story_17_0b do
      let(:asset_helper) do
        obj = Object.new
        obj.extend(described_class)
        obj
      end

      context "when in dev with the Vite dev server running" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
          allow(asset_helper).to receive(:vite_dev_running?).and_return(true)
        end

        it "emits NOTHING — the dev server injects the CSS through JS" do
          # Linking the on-disk file here would serve a stale build alongside
          # what Vite is injecting live.
          expect(asset_helper.ruact_head_assets).to eq("")
        end

        it "does not even consult the manifest in dev" do
          allow(asset_helper).to receive(:vite_manifest_entry)
          asset_helper.ruact_head_assets
          expect(asset_helper).not_to have_received(:vite_manifest_entry)
        end
      end

      context "when in prod (Vite manifest lookup)" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        end

        it "reads the SAME manifest entry the script tag uses (one build, never two)" do
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
          asset_helper.ruact_head_assets
          expect(asset_helper).to have_received(:vite_manifest_entry).with(Ruact.bootstrap_virtual_id)
        end

        it "emits one <link rel=\"stylesheet\"> per file in the entry's css array", :aggregate_failures do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .with(Ruact.bootstrap_virtual_id)
            .and_return({ "file" => "bootstrap-abc.js", "css" => ["bootstrap-def.css", "vendor-ghi.css"] })
          html = asset_helper.ruact_head_assets
          expect(html).to include(%(<link rel="stylesheet" href="/assets/bootstrap-def.css">))
          expect(html).to include(%(<link rel="stylesheet" href="/assets/vendor-ghi.css">))
          expect(html.scan("<link").length).to eq(2)
        end

        it "emits no script tag — the JS half is not this helper's job" do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .and_return({ "file" => "bootstrap-abc.js", "css" => ["a.css"] })
          expect(asset_helper.ruact_head_assets).not_to include("<script")
        end

        it "emits nothing when the entry declares no css" do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .and_return({ "file" => "bootstrap-abc.js" })
          expect(asset_helper.ruact_head_assets).to eq("")
        end

        it "emits nothing when the manifest entry is missing entirely" do
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
          expect(asset_helper.ruact_head_assets).to eq("")
        end

        it "returns an html_safe buffer" do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .and_return({ "file" => "b.js", "css" => ["a.css"] })
          expect(asset_helper.ruact_head_assets).to be_html_safe
        end

        # Vite writes this array in dependency order. Emitting it in any other
        # order changes which rule wins, so the order is part of the contract.
        it "preserves the manifest's own order" do
          allow(asset_helper).to receive(:vite_manifest_entry)
            .and_return({ "file" => "b.js", "css" => %w[first.css second.css third.css] })
          html = asset_helper.ruact_head_assets

          expect(html.scan(%r{/assets/(\S+?\.css)}).flatten).to eq(%w[first.css second.css third.css])
        end
      end

      # Review round 1 showed the "same build" promise was not kept: each helper
      # did its own file read, so a deploy landing between the two calls served
      # one build's stylesheet beside another build's script — in the same render.
      context "when both helpers run in one render (the same-build guarantee)" do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        end

        it "caches a MISSING entry too, so an absent manifest cannot reappear mid-render" do
          # Memoizing only truthy values would re-read on every nil, which is
          # exactly the window a deploy lands in.
          allow(asset_helper).to receive(:read_vite_manifest_entry).and_return(nil)

          asset_helper.ruact_head_assets
          asset_helper.ruact_js_assets

          expect(asset_helper).to have_received(:read_vite_manifest_entry).once
        end

        it "reads the manifest ONCE per render, so both helpers describe one build" do
          allow(asset_helper).to receive(:read_vite_manifest_entry)
            .and_return({ "file" => "b.js", "css" => ["a.css"] })

          asset_helper.ruact_head_assets
          asset_helper.ruact_js_assets

          expect(asset_helper).to have_received(:read_vite_manifest_entry).once
        end
      end
    end

    # Story 17.0f (AC5) — every document ruact renders tells Turbo Drive not to
    # swap it in: `turbo-visit-control: reload` makes Turbo do a full load, so the
    # ruact router never ends up living inside a Turbo-owned document (the
    # 2026-09-12 spike: S3–S7, dead links and blank pages after one round trip).
    describe "#ruact_head_assets — the Turbo meta", :story_17_0f do
      let(:meta) { %(<meta name="turbo-visit-control" content="reload">) }
      let(:prefetch) { %(<meta name="turbo-prefetch" content="false">) }
      let(:asset_helper) do
        obj = Object.new
        obj.extend(described_class)
        obj
      end

      def in_ruact_render(helper)
        # What `render_ruact_document` sets for the render (copied into the view
        # by Rails' view_assigns): the signal that this document is ruact's.
        helper.instance_variable_set(:@ruact_flight_payload, "0:[]\n")
        helper
      end

      it "is emitted in development with the Vite dev server running — it does not depend on Vite" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        allow(asset_helper).to receive(:vite_dev_running?).and_return(true)

        expect(in_ruact_render(asset_helper).ruact_head_assets).to eq("#{meta}\n#{prefetch}")
      end

      # Turbo 8 prefetches links on hover; in a ruact document the ruact router
      # owns the click, so a prefetch only runs the destination's action for
      # nothing.
      it "turns Turbo's hover prefetch off in a ruact document, and only there", :aggregate_failures do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        allow(asset_helper).to receive(:vite_dev_running?).and_return(true)

        expect(asset_helper.ruact_head_assets).not_to include("turbo-prefetch")
        expect(in_ruact_render(asset_helper).ruact_head_assets).to include(prefetch)
      end

      it "comes before the component stylesheets in production", :aggregate_failures do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        allow(asset_helper).to receive(:vite_manifest_entry).and_return({ "file" => "b.js", "css" => ["a.css"] })

        html = in_ruact_render(asset_helper).ruact_head_assets

        expect(html).to start_with(meta)
        expect(html).to include(%(<link rel="stylesheet" href="/assets/a.css">))
      end

      # Whole-app mode: the app's own layout calls this helper and ALSO renders
      # plain Rails pages. The meta there would make Turbo reload on every visit.
      it "is NOT emitted outside a ruact render, even from the same layout" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        allow(asset_helper).to receive(:vite_dev_running?).and_return(true)

        expect(asset_helper.ruact_head_assets).not_to include("turbo-visit-control")
      end
    end

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

        it "shows no Vite warning (Story 17-0k)" do
          expect(asset_helper.ruact_js_assets(payload)).not_to include("data-ruact-vite-down")
        end

        it "returns an html_safe buffer" do
          expect(asset_helper.ruact_js_assets(payload)).to be_html_safe
        end
      end

      # Story 17-0k — `bin/rails server` alone after Vite has run once: the
      # page answered 200 with an empty #root and nothing said why.
      context "when in dev with neither the Vite dev server nor a build", :story_17_0k do
        let(:logger) { instance_double(Logger, warn: nil) }

        before do
          allow(Rails).to receive_messages(env: ActiveSupport::StringInquirer.new("development"), logger: logger)
          allow(asset_helper).to receive_messages(vite_dev_running?: false, vite_manifest_entry: nil)
        end

        it "shows a warning on the page that does not need the bundle", :aggregate_failures do
          html = asset_helper.ruact_js_assets(payload)
          expect(html).to include("data-ruact-vite-down")
          expect(html).to include("The Vite dev server is not running (http://localhost:5173)")
          expect(html).to include("bin/dev")
          expect(html).to match(/<div role="alert"[^>]*style="position:fixed/)
        end

        it "logs the same diagnosis" do
          asset_helper.ruact_js_assets(payload)
          expect(logger).to have_received(:warn).with(/\[ruact\] The Vite dev server is not running/)
        end
      end

      context "when in dev without the Vite dev server but with a build", :story_17_0k do
        before do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
          allow(asset_helper).to receive_messages(vite_dev_running?: false,
                                                  vite_manifest_entry: { "file" => "bootstrap-abc.js" })
        end

        it "serves the build and warns about nothing" do
          expect(asset_helper.ruact_js_assets(payload)).not_to include("data-ruact-vite-down")
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

        it "never shows the development warning, even with no build (Story 17-0k)" do
          allow(asset_helper).to receive(:vite_manifest_entry).and_return(nil)
          expect(asset_helper.ruact_js_assets(payload)).not_to include("data-ruact-vite-down")
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

# The inline payload carries application data. A record whose text contained
# `</SCRIPT>` closed the bootstrap `<script>` (only a lowercase `</script>` was
# escaped) and the rest ran as HTML: stored XSS from any prop.
RSpec.describe "Ruact::ViewHelper inline Flight payload" do
  let(:helper) { Object.new.extend(Ruact::ViewHelper) }

  def pushed_literal(payload)
    script = helper.send(:ruact_flight_data_script, payload)
    script[/^\s*d\.push\((.*)\);$/, 1]
  end

  [
    "</SCRIPT><img src=x onerror=alert(1)>",
    "</script ><img src=x onerror=alert(1)>",
    "</ScRiPt\t><b>",
    "<!--<script>",
    "a & b > c",
    "line sep para",
    "escape \e bell \a nul \u0000",
    "emoji 😀 and ção",
    %(quotes " and \\ backslash)
  ].each do |text|
    it "embeds #{text.inspect} so it cannot leave the script and arrives intact", :aggregate_failures do
      payload = %(0:{"title":#{JSON.generate(text)}}\n)
      literal = pushed_literal(payload)

      expect(literal).not_to match(/[<>&  ]/)
      expect(JSON.parse(literal)).to eq(payload)
    end
  end
end
