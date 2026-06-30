# frozen_string_literal: true

require "spec_helper"
require "active_support/concern"
# Re-run-5 (2026-05-15) — the `:current_user` inherited-helper clobber
# test creates a `Class.new(ActionController::Base)`, which requires
# `action_controller` to be loaded. Pre-Re-run-5 this test was the
# first thing in the suite to demand-load `action_controller`,
# which had the side effect of triggering `Rails::Application`'s
# class definition AFTER spec_helper's `require "ruact"` ran — so
# `Ruact::Railtie` never got loaded into the process and downstream
# specs that depend on the Railtie's `to_prepare` hook would behave
# inconsistently. Loading both explicitly here makes the order
# deterministic.
require "action_controller"
require "ruact"
require "ruact/controller"

module Ruact
  RSpec.describe Controller do
    let(:test_class) do
      Class.new do
        include Ruact::Controller

        attr_reader :request

        def initialize(fake_request)
          @request = fake_request
        end
      end
    end

    # Minimal test double — `headers`, `format`, and `accepts` needed for the
    # methods under test. `format` must be a public struct member (not
    # Kernel#format) so that verify_partial_doubles can stub it. Story 10.0:
    # `#default_render` now keys off `request.accepts` (HTML acceptability), so
    # `accepts` is a settable member too.
    let(:fake_request) { Struct.new(:headers, :format, :accepts).new({}, nil, []) }
    let(:controller)   { test_class.new(fake_request) }

    describe "#ruact_manifest" do
      # Opt OUT of spec_helper's suite-wide resolver stub here so this proves the
      # actual delegation: `#ruact_manifest` resolves through ManifestResolver
      # (prod returns the boot-loaded Ruact.manifest; dev fetches over HTTP).
      it "delegates manifest resolution to ManifestResolver.resolve" do
        test_manifest = ClientManifest.from_hash({})
        allow(ManifestResolver).to receive(:resolve).and_return(test_manifest)

        expect(controller.send(:ruact_manifest)).to be test_manifest
        expect(ManifestResolver).to have_received(:resolve)
      end
    end

    describe "#ruact_request?" do
      it "returns true when Accept: text/x-component" do
        fake_request.headers["Accept"] = "text/x-component"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns true when Accept header includes text/x-component alongside other types" do
        fake_request.headers["Accept"] = "text/x-component, */*"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns true when Ruact-Request: 1 header is set" do
        fake_request.headers["Ruact-Request"] = "1"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns false when Accept: text/html" do
        fake_request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        expect(controller.send(:ruact_request?)).to be false
      end

      it "returns false when no Accept header is set" do
        expect(controller.send(:ruact_request?)).to be false
      end
    end

    describe "#default_render" do
      # Story 10.0 — the activation predicate keys off HTML *acceptability*
      # (`request.accepts`), not `request.format.html?`. `request.format.html?`
      # is false for a `*/*` wildcard, which 500'd those requests pre-10.0.
      before do
        allow(controller).to receive(:ruact_template_exists?).and_return(true)
        allow(controller).to receive(:ruact_render)
      end

      it "calls ruact_render when the client accepts text/html and template exists (AC#1)" do
        fake_request.accepts = [Mime[:html]]
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "calls ruact_render for a */* wildcard Accept — Mime::ALL (Story 10.0 AC#1)" do
        fake_request.accepts = [Mime::ALL]
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "calls ruact_render when Accept is blank (defaults to HTML) (Story 10.0 AC#1)" do
        fake_request.accepts = []
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "calls ruact_render for RSC requests (text/x-component) even when HTML is unacceptable (AC#1)" do
        fake_request.accepts = [Mime[:json]]
        fake_request.headers["Ruact-Request"] = "1"
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "does NOT call ruact_render for a concrete non-HTML Accept that is not RSC (AC#4 — FR26)" do
        fake_request.accepts = [Mime[:json]]
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:ruact_render)
      end

      it "does NOT call ruact_render when no template exists" do
        allow(controller).to receive(:ruact_template_exists?).and_return(false)
        fake_request.accepts = [Mime[:html]]
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:ruact_render)
      end
    end

    describe "#redirect_to" do
      # Build a class hierarchy so `super` inside the override can call a base implementation.
      # url_for and render must be defined for verify_partial_doubles to allow stubbing them.
      let(:redirect_test_class) do
        base = Class.new do
          def redirect_to(*)
            :super_called
          end

          def url_for(options)
            options.is_a?(String) ? options : "/"
          end

          def render(**_opts); end
        end
        Class.new(base) do
          include Ruact::Controller

          attr_reader :request

          def initialize(req)
            super()
            @request = req
          end
        end
      end

      let(:ruact_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({ "Accept" => "text/x-component" }, "localhost"))
      end
      let(:html_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({}, "localhost"))
      end

      context "when RSC request with same-origin URL (AC #1, #5)" do
        before { allow(ruact_ctrl).to receive(:url_for).and_return("/posts/1") }

        it "calls render with a Flight redirect row (not a 302)" do
          allow(ruact_ctrl).to receive(:render)
          ruact_ctrl.send(:redirect_to, "/posts/1")
          expect(ruact_ctrl).to have_received(:render).with(
            plain: "0:{\"redirectUrl\":\"/posts/1\",\"redirectType\":\"push\"}\n",
            content_type: "text/x-component"
          )
        end

        it "redirect row matches the flight fixture (AC #5)" do
          rendered_plain = nil
          allow(ruact_ctrl).to receive(:render) { |opts| rendered_plain = opts[:plain] }
          ruact_ctrl.send(:redirect_to, "/posts/1")
          expect(rendered_plain).to match_flight_fixture("redirect_row")
        end
      end

      context "when RSC request with external URL (AC #3)" do
        before { allow(ruact_ctrl).to receive(:url_for).and_return("https://external.com/page") }

        it "does NOT emit a redirect row (falls back to super)" do
          allow(ruact_ctrl).to receive(:render)
          ruact_ctrl.send(:redirect_to, "https://external.com/page")
          expect(ruact_ctrl).not_to have_received(:render)
        end
      end

      context "when non-RSC request (AC #4)" do
        before { allow(html_ctrl).to receive(:url_for).and_return("/posts/1") }

        it "does NOT emit a redirect row (falls back to super)" do
          allow(html_ctrl).to receive(:render)
          html_ctrl.send(:redirect_to, "/posts/1")
          expect(html_ctrl).not_to have_received(:render)
        end
      end
    end

    describe "#ruact_html_shell" do
      # Story 14.2 — the entry `<script>` tags are emitted by the mixed-in
      # ViewHelper#ruact_vite_tags (which needs Rails.env / a live Vite probe).
      # Stub it to "" so we test the shell structure + the __FLIGHT_DATA script
      # (still emitted by ruact_js_assets) in isolation.
      before { allow(controller).to receive(:ruact_vite_tags).and_return("") }

      let(:payload) { "0:[\"$\",\"div\",null,{}]\n" }

      it "returns a string containing window.__FLIGHT_DATA" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include("__FLIGHT_DATA")
      end

      it "wraps the payload in an IIFE push" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include("d.push(")
      end

      it "contains a root div#root element" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include('<div id="root">')
      end

      it "escapes </script> in the payload to prevent XSS breakout" do
        dangerous_payload = "0:\"</script><script>alert(1)</script>\"\n"
        html = controller.send(:ruact_html_shell, dangerous_payload)
        # The HTML must contain exactly ONE </script> — the real closing tag of the script block.
        # If the payload's </script> leaked through, there would be more than one.
        occurrences = html.scan("</script>")
        count = occurrences.length
        expect(count).to eq(1), "Expected 1 </script> (closing tag), found #{count}"
      end

      # Story 8.3 review R7 — the shell must surface the host's CSRF token
      # as a `<meta name="csrf-token">` tag so the JS runtime can forward
      # it as `X-CSRF-Token` on every `_makeRef` call. Without this,
      # standalone server actions (Story 8.3 AC5) — for which the gem
      # enforces CSRF itself via `protect_from_forgery with: :exception,
      # if: :dispatching_standalone?` — can never authenticate, because
      # the document has no token for the runtime to read.
      context "Story 8.3 — CSRF meta tag injection", :story_8_3 do
        # The bare `test_class` above is a minimal `include Ruact::Controller`
        # consumer with no `form_authenticity_token` surface (no Rails
        # request-forgery-protection module mixed in). Define a real method
        # on the class so `respond_to?(:form_authenticity_token, true)` is
        # true AND `verify_partial_doubles` lets us stub the return value.
        let(:csrf_test_class) do
          Class.new(test_class) do
            def form_authenticity_token
              "stub-default-token"
            end
          end
        end
        let(:csrf_controller) { csrf_test_class.new(fake_request) }

        # Story 14.2 — csrf_controller is a separate instance from `controller`,
        # so the outer `before` stub does not reach it. Stub its entry-tag
        # emission too (the real path would hit Rails.root in a non-booted env),
        # keeping these CSRF tests order-independent.
        before { allow(csrf_controller).to receive(:ruact_vite_tags).and_return("") }

        it "embeds <meta name=\"csrf-token\" content=\"...\"> when the host exposes form_authenticity_token" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return("test-csrf-token-value")
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).to include('<meta name="csrf-token" content="test-csrf-token-value" />')
        end

        it "HTML-escapes the token value (defense against accidental quote injection)" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return('"quoted" & <evil>')
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).to include("&quot;quoted&quot; &amp; &lt;evil&gt;")
          expect(html).not_to include('"quoted" & <evil>')
        end

        it "omits the meta tag (renders empty string) when form_authenticity_token is not available " \
           "(e.g., a non-Rails spec context)" do
          # `controller` is the bare test_class without `form_authenticity_token`.
          html = controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end

        it "omits the meta tag when form_authenticity_token returns nil/empty" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return("")
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end

        it "silently omits the meta tag if form_authenticity_token raises " \
           "(e.g., session middleware missing in a stripped-down test env)" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_raise(StandardError, "no session")
          expect { csrf_controller.send(:ruact_html_shell, payload) }.not_to raise_error
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end
      end
    end

    # Story 14.2 (FR104) — the controller's HTML shell delegates its JS asset
    # markup (entry tags + __FLIGHT_DATA) to the single
    # Ruact::ViewHelper#ruact_js_assets implementation. No duplicated tag logic;
    # controller output == a view helper's output (parity guards against drift).
    describe "ruact_js_assets delegation + parity", :story_14_2 do
      let(:payload) { "0:[\"$\",\"div\",null,{}]\n" }

      it "delegates the JS block to ruact_js_assets (single implementation)" do
        allow(controller).to receive(:ruact_js_assets).with(payload).and_return("<!--RUACT-JS-->".html_safe)
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include("<!--RUACT-JS-->")
        expect(controller).to have_received(:ruact_js_assets).with(payload)
      end

      it "emits markup byte-identical to a standalone view helper (no drift)" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        manifest_entry = { "file" => "bootstrap-xyz789.js" }
        allow(controller).to receive(:vite_manifest_entry).and_return(manifest_entry)

        view = Object.new
        view.extend(Ruact::ViewHelper)
        allow(view).to receive(:vite_manifest_entry).and_return(manifest_entry)

        expect(controller.send(:ruact_js_assets, payload)).to eq(view.ruact_js_assets(payload))
      end

      it "exposes ruact_js_assets as PRIVATE on the controller (never a routable action)", :aggregate_failures do
        expect(controller.class.public_method_defined?(:ruact_js_assets)).to be false
        expect(controller.class.private_method_defined?(:ruact_js_assets)).to be true
        # __ruact_component__ is likewise demoted so it is not exposed as an action.
        expect(controller.class.public_method_defined?(:__ruact_component__)).to be false
      end
    end
  end
end
