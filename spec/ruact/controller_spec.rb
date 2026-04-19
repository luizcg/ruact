# frozen_string_literal: true

require "spec_helper"
require "active_support/concern"
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

    # Minimal test double — `headers` + `format` needed for the methods under test.
    # `format` must be a public struct member (not Kernel#format) so that
    # verify_partial_doubles can stub it in #default_render tests.
    let(:fake_request) { Struct.new(:headers, :format).new({}, nil) }
    let(:controller)   { test_class.new(fake_request) }

    describe "#rsc_manifest" do
      it "reads from Ruact.manifest (AC#6)" do
        test_manifest = ClientManifest.from_hash({})
        allow(Ruact).to receive(:manifest).and_return(test_manifest)
        expect(controller.send(:rsc_manifest)).to be test_manifest
      end
    end

    describe "#rsc_request?" do
      it "returns true when Accept: text/x-component" do
        fake_request.headers["Accept"] = "text/x-component"
        expect(controller.send(:rsc_request?)).to be true
      end

      it "returns true when Accept header includes text/x-component alongside other types" do
        fake_request.headers["Accept"] = "text/x-component, */*"
        expect(controller.send(:rsc_request?)).to be true
      end

      it "returns true when RSC-Request: 1 header is set" do
        fake_request.headers["RSC-Request"] = "1"
        expect(controller.send(:rsc_request?)).to be true
      end

      it "returns false when Accept: text/html" do
        fake_request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        expect(controller.send(:rsc_request?)).to be false
      end

      it "returns false when no Accept header is set" do
        expect(controller.send(:rsc_request?)).to be false
      end
    end

    describe "#default_render" do
      let(:html_format) { Class.new { def html? = true }.new }
      let(:json_format) { Class.new { def html? = false }.new }

      before do
        allow(controller).to receive(:rsc_template_exists?).and_return(true)
        allow(controller).to receive(:rsc_render)
      end

      it "calls rsc_render when format is HTML and template exists (AC#1)" do
        allow(fake_request).to receive(:format).and_return(html_format)
        controller.send(:default_render)
        expect(controller).to have_received(:rsc_render)
      end

      it "calls rsc_render for RSC requests (text/x-component) even without html? (AC#1)" do
        allow(fake_request).to receive(:format).and_return(json_format)
        fake_request.headers["RSC-Request"] = "1"
        controller.send(:default_render)
        expect(controller).to have_received(:rsc_render)
      end

      it "does NOT call rsc_render when format is not HTML and not RSC (AC#5, AC#6 — FR26)" do
        allow(fake_request).to receive(:format).and_return(json_format)
        allow(controller).to receive(:rsc_render)
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:rsc_render)
      end

      it "does NOT call rsc_render when no template exists" do
        allow(controller).to receive(:rsc_template_exists?).and_return(false)
        allow(fake_request).to receive(:format).and_return(html_format)
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:rsc_render)
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

      let(:rsc_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({ "Accept" => "text/x-component" }, "localhost"))
      end
      let(:html_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({}, "localhost"))
      end

      context "when RSC request with same-origin URL (AC #1, #5)" do
        before { allow(rsc_ctrl).to receive(:url_for).and_return("/posts/1") }

        it "calls render with a Flight redirect row (not a 302)" do
          allow(rsc_ctrl).to receive(:render)
          rsc_ctrl.send(:redirect_to, "/posts/1")
          expect(rsc_ctrl).to have_received(:render).with(
            plain: "0:{\"redirectUrl\":\"/posts/1\",\"redirectType\":\"push\"}\n",
            content_type: "text/x-component"
          )
        end

        it "redirect row matches the flight fixture (AC #5)" do
          rendered_plain = nil
          allow(rsc_ctrl).to receive(:render) { |opts| rendered_plain = opts[:plain] }
          rsc_ctrl.send(:redirect_to, "/posts/1")
          expect(rendered_plain).to match_flight_fixture("redirect_row")
        end
      end

      context "when RSC request with external URL (AC #3)" do
        before { allow(rsc_ctrl).to receive(:url_for).and_return("https://external.com/page") }

        it "does NOT emit a redirect row (falls back to super)" do
          allow(rsc_ctrl).to receive(:render)
          rsc_ctrl.send(:redirect_to, "https://external.com/page")
          expect(rsc_ctrl).not_to have_received(:render)
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

    describe "#rsc_html_shell" do
      # vite_tags requires Rails.env — stub it so we can test the shell structure.
      before { allow(controller).to receive(:vite_tags).and_return("") }

      let(:payload) { "0:[\"$\",\"div\",null,{}]\n" }

      it "returns a string containing window.__FLIGHT_DATA" do
        html = controller.send(:rsc_html_shell, payload)
        expect(html).to include("__FLIGHT_DATA")
      end

      it "wraps the payload in an IIFE push" do
        html = controller.send(:rsc_html_shell, payload)
        expect(html).to include("d.push(")
      end

      it "contains a root div#root element" do
        html = controller.send(:rsc_html_shell, payload)
        expect(html).to include('<div id="root">')
      end

      it "escapes </script> in the payload to prevent XSS breakout" do
        dangerous_payload = "0:\"</script><script>alert(1)</script>\"\n"
        html = controller.send(:rsc_html_shell, dangerous_payload)
        # The HTML must contain exactly ONE </script> — the real closing tag of the script block.
        # If the payload's </script> leaked through, there would be more than one.
        occurrences = html.scan("</script>")
        count = occurrences.length
        expect(count).to eq(1), "Expected 1 </script> (closing tag), found #{count}"
      end
    end
  end
end
