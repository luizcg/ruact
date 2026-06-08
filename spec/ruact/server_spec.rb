# frozen_string_literal: true

# Story 9.1 — unit surface of the `Ruact::Server` concern (route-driven
# redesign, Phase A). Pins:
#
#   - AC1 "and nothing else": including the concern installs EXACTLY two
#     `rescue_from` handlers + one prepended before_action, adds no public
#     instance methods, and registers nothing in the v1 registries (codegen
#     exposure is Story 9.3's job — the concern is a pure marker + salvage
#     host until then).
#   - AC2 / D3: the `__ruact_function_call?` predicate matrix — the single
#     named discrimination point Story 9.2 reuses. Keyed on the raw `Accept`
#     header containing `application/json` (what the 8.1 runtime sends on
#     every `_makeRef` fetch); deliberately NOT `request.format`, which is
#     influenced by path extensions and `params[:format]`.
#
# Request-cycle behavior (error chain, upload guard) is pinned by
# `server_rescue_request_spec.rb` / `server_upload_request_spec.rb`.

require "action_controller/railtie"

require "spec_helper"
require "open3"

require "ruact/server"

module ServerConcernUnitSupport
  # Baseline for "nothing else" comparisons.
  class PlainController < ActionController::Base
  end

  class ConcernController < ActionController::Base
    include Ruact::Server
  end
end

RSpec.describe Ruact::Server, :story_9_1 do
  describe "Story 9.1 — installation surface (AC1: the salvaged chains and nothing else)" do
    it "installs exactly the two salvaged rescue_from handlers, in the v1 registration order" do
      # Pitfall #1 parity: StandardError first, explicit
      # InvalidAuthenticityToken second — the later registration wins the
      # most-recently-registered walk, preempting Rails' default
      # handle_unverified_request for CSRF failures.
      expect(ServerConcernUnitSupport::PlainController.rescue_handlers).to eq([])
      expect(ServerConcernUnitSupport::ConcernController.rescue_handlers.map(&:first)).to eq(
        ["StandardError", "ActionController::InvalidAuthenticityToken"]
      )
    end

    it "prepends the upload guard as the FIRST before_action (Pitfall #4 ordering)" do
      before_filters = ServerConcernUnitSupport::ConcernController
                       ._process_action_callbacks
                       .select { |callback| callback.kind == :before }
                       .map(&:filter)
      expect(before_filters.first).to eq(:__ruact_enforce_upload_limit!)
    end

    it "adds NO public instance methods to the host (predicate + handlers are private)" do
      added = ServerConcernUnitSupport::ConcernController.public_instance_methods -
              ServerConcernUnitSupport::PlainController.public_instance_methods
      expect(added).to eq([])
    end

    it "registers nothing in the v1 registries (codegen exposure is Story 9.3, not 9.1)" do
      expect(Ruact.action_registry.entries).to be_empty
      expect(Ruact.query_registry.entries).to be_empty
    end

    it "keeps INHERITED host rescue_from handlers more recent than its own (review patch)",
       :aggregate_failures do
      # Rails resolves handlers by walking `rescue_handlers` from the most
      # recently registered entry backwards. The concern therefore places its
      # entries at the FRONT of the array, so every host handler — inherited
      # from a parent class or declared after the include — stays more recent
      # and keeps precedence.
      parent = Class.new(ActionController::Base) do
        rescue_from ArgumentError, with: :host_handler
      end
      child = Class.new(parent) { include Ruact::Server }
      expect(child.rescue_handlers.map(&:first)).to eq(
        ["StandardError", "ActionController::InvalidAuthenticityToken", "ArgumentError"]
      )
      # The parent's own registry is untouched (class_attribute write lands
      # on the child only).
      expect(parent.rescue_handlers.map(&:first)).to eq(["ArgumentError"])
    end
  end

  describe "Story 9.1 — standalone load path (review patch)" do
    it "a direct require \"ruact/server\" resolves Ruact.config and the error constants" do
      lib = File.expand_path("../../lib", __dir__)
      script = <<~RUBY
        require "ruact/server"
        exit 1 unless defined?(Ruact::Server)
        exit 2 unless defined?(Ruact::UploadTooLargeError)
        exit 3 unless Ruact.config.respond_to?(:max_upload_bytes)
        exit 4 unless defined?(Ruact::ServerFunctions::ErrorRendering)
      RUBY
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
      expect(status).to be_success, "standalone require failed (exit #{status.exitstatus}): #{stderr}"
    end
  end

  # Review patch (2026-06-08) — the raw `Accept: application/json` detection is
  # now its own helper, distinct from the SEMANTIC function-call predicate.
  # `__ruact_json_accept?` is the verb-agnostic header check; the matrix that
  # used to live on `__ruact_function_call?` belongs here.
  describe "Story 9.1 — __ruact_json_accept? raw-header matrix (AC2 / D3, review patch)" do
    let(:controller) { ServerConcernUnitSupport::ConcernController.new }

    def stub_accept_header(value)
      request = instance_double(ActionDispatch::Request)
      allow(request).to receive(:headers).and_return({ "Accept" => value })
      allow(controller).to receive(:request).and_return(request)
    end

    it "is true for the runtime's exact shape (Accept: application/json)" do
      stub_accept_header("application/json")
      expect(controller.send(:__ruact_json_accept?)).to be(true)
    end

    it "is true when application/json appears in a composite Accept (axios-style)" do
      stub_accept_header("application/json, text/plain, */*")
      expect(controller.send(:__ruact_json_accept?)).to be(true)
    end

    it "is false for browser navigation Accept headers" do
      stub_accept_header("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
      expect(controller.send(:__ruact_json_accept?)).to be(false)
    end

    it "is false for Flight requests (Accept: text/x-component)" do
      stub_accept_header("text/x-component")
      expect(controller.send(:__ruact_json_accept?)).to be(false)
    end

    it "is false when the Accept header is absent (strict boolean, not nil)" do
      stub_accept_header(nil)
      expect(controller.send(:__ruact_json_accept?)).to be(false)
    end

    # Review patch (2026-06-08, round 3) — the predicate now parses media
    # ranges and token boundaries instead of a raw substring match, so it no
    # longer mistakes near-misses for JSON-Accept. Because `__ruact_function_call?`
    # feeds Story 9.2's discriminator, a substring false-positive would route
    # ordinary requests into Ruact's structured payload.
    it "is false for application/jsonp (token boundary, not a substring match)" do
      stub_accept_header("application/jsonp")
      expect(controller.send(:__ruact_json_accept?)).to be(false)
    end

    it "is false for application/json;q=0 (explicitly NOT acceptable)" do
      stub_accept_header("text/html, application/json;q=0")
      expect(controller.send(:__ruact_json_accept?)).to be(false)
    end

    it "is true for Application/JSON (media types are case-insensitive)" do
      stub_accept_header("Application/JSON")
      expect(controller.send(:__ruact_json_accept?)).to be(true)
    end

    it "is true for application/json;q=0.5 (positive q-value)" do
      stub_accept_header("application/json;q=0.5, text/plain")
      expect(controller.send(:__ruact_json_accept?)).to be(true)
    end
  end

  # Review patch (2026-06-08) — `__ruact_function_call?` is now the SEMANTIC
  # predicate Story 9.2 reuses: a JSON-Accept request that is ALSO non-GET/HEAD
  # (function calls are non-GET by the verb rule, epic contract decision #1).
  # The verb gate moved off the error-renderer and into the predicate itself,
  # so 9.2 inherits the correct contract from one place.
  describe "Story 9.1 — __ruact_function_call? semantic predicate (verb-gated, review patch)" do
    let(:controller) { ServerConcernUnitSupport::ConcernController.new }

    def stub_request(accept:, verb: "POST")
      request = instance_double(
        ActionDispatch::Request,
        headers: { "Accept" => accept },
        get?: verb == "GET",
        head?: verb == "HEAD"
      )
      allow(controller).to receive(:request).and_return(request)
    end

    it "is true for a non-GET JSON request (THE Story 9.2 discrimination point)" do
      stub_request(accept: "application/json", verb: "POST")
      expect(controller.send(:__ruact_function_call?)).to be(true)
    end

    it "is false for a GET carrying Accept: application/json (verb rule — not a function call)" do
      stub_request(accept: "application/json", verb: "GET")
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end

    it "is false for a HEAD carrying Accept: application/json" do
      stub_request(accept: "application/json", verb: "HEAD")
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end

    it "is false for a non-GET request without a JSON Accept (Bucket-1 form submit)" do
      stub_request(accept: "text/html", verb: "POST")
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end
  end

  # Review patch (2026-06-08) — AC4 / Pitfall #4 made executable. A host that
  # re-orders CSRF ahead of the prepended upload guard via
  # `protect_from_forgery prepend: true` would 403 an oversized tokenless
  # multipart request before the intended 413. The concern detects the
  # inversion in the compiled callback chain and fails loudly rather than
  # documenting it as the host's responsibility.
  describe "Story 9.1 — upload guard must precede CSRF verification (AC4 / Pitfall #4, review patch)" do
    let(:inverted_controller_class) do
      Class.new(ActionController::Base) do
        include Ruact::Server

        protect_from_forgery with: :exception, prepend: true
      end
    end

    let(:ordered_controller_class) do
      Class.new(ActionController::Base) do
        include Ruact::Server

        protect_from_forgery with: :exception
      end
    end

    it "detects the inversion when verify_authenticity_token is prepended ahead of the guard" do
      expect(inverted_controller_class.new.send(:__ruact_csrf_precedes_upload_guard?)).to be(true)
    end

    it "does not flag a controller whose CSRF check follows the prepended guard" do
      expect(ordered_controller_class.new.send(:__ruact_csrf_precedes_upload_guard?)).to be(false)
    end

    it "does not flag a controller without CSRF protection at all" do
      expect(
        ServerConcernUnitSupport::ConcernController.new.send(:__ruact_csrf_precedes_upload_guard?)
      ).to be(false)
    end

    # Review patch (2026-06-08, round 3) — the detector reduced callbacks to
    # raw filter names and ignored `if`/`unless`/`only`/`except`, so a CSRF
    # callback that can NEVER run on a real request still produced a spurious
    # ConfigurationError. The detector now narrows to UNCONDITIONAL CSRF
    # callbacks (the genuine `protect_from_forgery prepend: true` misconfig is
    # unconditional, so it is still caught).
    context "with a CONDITIONAL CSRF callback (review patch round 3)" do
      let(:disabled_if_class) do
        Class.new(ActionController::Base) do
          include Ruact::Server

          protect_from_forgery with: :exception, prepend: true, if: -> { false }
        end
      end

      let(:action_scoped_class) do
        Class.new(ActionController::Base) do
          include Ruact::Server

          protect_from_forgery with: :exception, prepend: true, only: [:never_routed]
        end
      end

      it "does NOT flag a prepended-but-disabled CSRF callback (if: -> { false })" do
        expect(disabled_if_class.new.send(:__ruact_csrf_precedes_upload_guard?)).to be(false)
      end

      it "does NOT flag a prepended CSRF callback scoped to other actions (only:)" do
        expect(action_scoped_class.new.send(:__ruact_csrf_precedes_upload_guard?)).to be(false)
      end

      it "does NOT raise when the guard runs on a controller with a conditional CSRF callback" do
        controller = disabled_if_class.new
        request = instance_double(ActionDispatch::Request, get?: true, head?: false)
        allow(controller).to receive(:request).and_return(request)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "raises Ruact::ConfigurationError when the guard runs on an inverted controller" do
      controller = inverted_controller_class.new
      expect { controller.send(:__ruact_enforce_upload_limit!) }
        .to raise_error(Ruact::ConfigurationError, /verify_authenticity_token before/)
    end

    it "does NOT raise when the guard runs on a correctly-ordered controller" do
      controller = ordered_controller_class.new
      request = instance_double(ActionDispatch::Request, get?: true, head?: false)
      allow(controller).to receive(:request).and_return(request)
      expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
    end
  end
end
