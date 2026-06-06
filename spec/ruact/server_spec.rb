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
  end

  describe "Story 9.1 — __ruact_function_call? predicate matrix (AC2 / D3)" do
    let(:controller) { ServerConcernUnitSupport::ConcernController.new }

    def stub_accept_header(value)
      request = instance_double(ActionDispatch::Request)
      allow(request).to receive(:headers).and_return({ "Accept" => value })
      allow(controller).to receive(:request).and_return(request)
    end

    it "is true for the runtime's exact shape (Accept: application/json)" do
      stub_accept_header("application/json")
      expect(controller.send(:__ruact_function_call?)).to be(true)
    end

    it "is true when application/json appears in a composite Accept (axios-style)" do
      stub_accept_header("application/json, text/plain, */*")
      expect(controller.send(:__ruact_function_call?)).to be(true)
    end

    it "is false for browser navigation Accept headers" do
      stub_accept_header("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end

    it "is false for Flight requests (Accept: text/x-component)" do
      stub_accept_header("text/x-component")
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end

    it "is false when the Accept header is absent (strict boolean, not nil)" do
      stub_accept_header(nil)
      expect(controller.send(:__ruact_function_call?)).to be(false)
    end
  end
end
