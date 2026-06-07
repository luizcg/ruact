# frozen_string_literal: true

# Story 9.1 — request-cycle spec for the Story 8.4 structured-error chain
# RE-ANCHORED on the `Ruact::Server` concern (its final, v2 home). Replaces
# `server_functions/endpoint_controller_rescue_spec.rb` (removed in the same
# commit — AC5: no orphan salvage, no double coverage). Pins, against REAL
# host-controller routes (no `/__ruact/fn/` anywhere):
#
#   - structured payload on function-call requests: discriminator, baseline
#     fields, dev extras, validation_errors, suggestion (inventory A1, A2,
#     A5, A6, A9)
#   - host `rescue_from` precedence (A12)
#   - production-mode reduction to the four baseline keys (A8)
#   - strict-boolean `dev_error_payload_enabled` handling — review F3 (A10)
#   - server-side logging always fires (A11)
#   - CSRF failure → 403 + structured body with the CSRF suggestion (A13)
#   - AC1 byte-for-byte: GET page actions render untouched (C2); a raise on
#     a NON-function-call request propagates to Rails' default handling —
#     no structured JSON swallow (C3 / D1)
#
# Mounts on the shared Story-7.9 Rails app (`controller_request_spec.rb`).
# Deliberately does NOT depend on `server_functions/dispatch_request_spec.rb`
# — that file pins the v1 endpoint and is demolished in Story 9.9; this file
# must survive it.

require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"
require "rack/test"

require "ruact/server"

require "active_model"
require "active_record"
require "i18n"

# Locale loader (same pattern as the v1 request specs) so
# RecordInvalid#message resolves cleanly.
{
  "activemodel" => "active_model",
  "activerecord" => "active_record"
}.each do |gem_name, dir|
  spec = Gem.loaded_specs[gem_name]
  next unless spec

  locale_file = File.join(spec.gem_dir, "lib", dir, "locale", "en.yml")
  I18n.load_path << locale_file if File.exist?(locale_file)
end
I18n.backend.load_translations

# Constant-gated load of the shared Rails app — RSpec loads spec files via
# `Kernel.load` (no $LOADED_FEATURES dedupe), so an unconditional
# require_relative would re-run controller_request_spec.rb's top-level
# routes.append and crash with "Invalid route name, already in use".
require_relative "controller_request_spec" unless defined?(ControllerRequestSpecSupport)

module ServerRescueSpecSupport
  # The exact wire shape the 8.1 runtime sends on every `_makeRef` fetch:
  # JSON body + `Accept: application/json` — the Bucket-2 / function-call
  # request shape the concern's predicate keys on.
  FUNCTION_CALL_HEADERS = {
    "CONTENT_TYPE" => "application/json",
    "HTTP_ACCEPT" => "application/json"
  }.freeze

  # Lightweight ActiveModel-shaped class so we can construct a REAL
  # `ActiveRecord::RecordInvalid` instance.
  class RescuePost
    include ActiveModel::Model

    attr_accessor :title

    validates :title, presence: true

    def self.i18n_scope
      :activerecord
    end
  end

  # Host with NO rescue_from of its own — exceptions reach the concern's
  # salvaged `rescue_from StandardError`. Includes ONLY Ruact::Server: the
  # concern must work standalone (Bucket-1 rendering comes from the host's
  # separate Ruact::Controller include in real apps; coupling them is 9.2's
  # design space).
  class BareServerController < ActionController::Base
    include Ruact::Server

    def record_invalid
      record = RescuePost.new
      record.valid? # populates record.errors
      raise ActiveRecord::RecordInvalid, record
    end

    def argument_error
      raise ArgumentError, "bad arg"
    end

    def runtime_error
      raise "boom"
    end

    def create_ok
      render json: { "ok" => true }
    end

    def page
      render plain: "plain page body"
    end

    def erroring_page
      raise "boom on GET"
    end
  end

  # Parent WITHOUT the concern that catches RecordInvalid; the child includes
  # `Ruact::Server`. Proves the concern's chain does not preempt handlers the
  # host INHERITED either (review patch — `rescue_handlers` walks
  # most-recently-registered first, and a naive include lands the concern's
  # entries after the parent's).
  class ParentRescuingController < ActionController::Base
    rescue_from ActiveRecord::RecordInvalid do |error|
      render(
        json: { caught_by_parent: true, error_class: error.class.name },
        status: :unprocessable_entity
      )
    end
  end

  class InheritedCaughtServerController < ParentRescuingController
    include Ruact::Server

    def record_invalid
      record = RescuePost.new
      record.valid?
      raise ActiveRecord::RecordInvalid, record
    end
  end

  # Host that catches RecordInvalid itself — proves the concern's chain does
  # NOT preempt a host's own rescue_from (inventory A12).
  class CaughtServerController < ActionController::Base
    include Ruact::Server

    rescue_from ActiveRecord::RecordInvalid do |error|
      render(
        json: { caught_by_host: true, error_class: error.class.name },
        status: :unprocessable_entity
      )
    end

    def record_invalid
      record = RescuePost.new
      record.valid?
      raise ActiveRecord::RecordInvalid, record
    end
  end

  # Host with real CSRF enforcement — the concern's explicit
  # InvalidAuthenticityToken registration must render the structured 403
  # for function-call requests (inventory A13). Forgery is flipped on
  # per-example via `allow_forgery_protection` (class-level), mirroring the
  # v1 spec pattern — but on the HOST controller now, not EndpointController.
  class ForgeryServerController < ActionController::Base
    include Ruact::Server

    protect_from_forgery with: :exception

    def create_protected
      render json: { "ok" => true }
    end
  end
end

if defined?(ControllerRequestSpecSupport) &&
   !ControllerRequestSpecSupport.instance_variable_get(:@__ruact_server_rescue_routes_appended)
  ControllerRequestSpecSupport.instance_variable_set(:@__ruact_server_rescue_routes_appended, true)
  ControllerRequestSpecSupport.app_class.routes.append do
    get  "/server_rescue/page",                  to: "server_rescue_spec_support/bare_server#page"
    get  "/server_rescue/erroring_page",         to: "server_rescue_spec_support/bare_server#erroring_page"
    post "/server_rescue/record_invalid",        to: "server_rescue_spec_support/bare_server#record_invalid"
    post "/server_rescue/argument_error",        to: "server_rescue_spec_support/bare_server#argument_error"
    post "/server_rescue/runtime_error",         to: "server_rescue_spec_support/bare_server#runtime_error"
    post "/server_rescue/create_ok",             to: "server_rescue_spec_support/bare_server#create_ok"
    post "/server_rescue/caught_record_invalid", to: "server_rescue_spec_support/caught_server#record_invalid"
    post "/server_rescue/protected",             to: "server_rescue_spec_support/forgery_server#create_protected"
    post "/server_rescue/inherited_caught_record_invalid",
         to: "server_rescue_spec_support/inherited_caught_server#record_invalid"
  end
end

RSpec.describe "Story 9.1: Ruact::Server concern — salvaged rescue_from chain", :story_9_1 do
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  let(:function_call_headers) { ServerRescueSpecSupport::FUNCTION_CALL_HEADERS }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
  end

  describe "AC3 — function-call request: structured payload, wire contract preserved" do
    it "RecordInvalid on a bare host renders 422 + the full dev-mode payload (A1/A2/A5/A6/A9)",
       :aggregate_failures do
      post "/server_rescue/record_invalid", "{}", function_call_headers
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body).to include(
        "_ruact_server_action_error" => true,
        "action_name" => "record_invalid",
        "error_class" => "ActiveRecord::RecordInvalid"
      )
      expect(body.fetch("message")).to match(/Title can't be blank/)
      expect(body.fetch("validation_errors")).to include(/Title can't be blank/)
      expect(body.fetch("suggestion")).to eq("Validation failed — check the model's `validates` rules")
      expect(body).to have_key("app_frames")
      expect(body).to have_key("gem_frames")
    end

    it "ArgumentError renders 500 + structured payload with null suggestion (A9)", :aggregate_failures do
      post "/server_rescue/argument_error", "{}", function_call_headers
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("action_name")).to eq("argument_error")
      expect(body.fetch("error_class")).to eq("ArgumentError")
      expect(body.fetch("message")).to eq("bad arg")
      expect(body.fetch("suggestion")).to be_nil
    end

    it "RuntimeError renders 500 + structured payload (A9)" do
      post "/server_rescue/runtime_error", "{}", function_call_headers
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("RuntimeError")
      expect(body.fetch("message")).to eq("boom")
    end

    it "a non-raising action is untouched by the chain (happy path sanity)" do
      post "/server_rescue/create_ok", "{}", function_call_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("ok" => true)
    end
  end

  describe "host rescue_from precedence — host wins (A12)" do
    it "RecordInvalid handled by the host renders the host's body, NOT the structured payload" do
      post "/server_rescue/caught_record_invalid", "{}", function_call_headers
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("caught_by_host")).to be(true)
      expect(body).not_to have_key("_ruact_server_action_error")
    end

    it "RecordInvalid handled by an INHERITED parent handler also wins over the concern (review patch)" do
      post "/server_rescue/inherited_caught_record_invalid", "{}", function_call_headers
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("caught_by_parent")).to be(true)
      expect(body).not_to have_key("_ruact_server_action_error")
    end
  end

  describe "production-mode payload reduction (A8)" do
    before { Ruact.configure { |c| c.dev_error_payload_enabled = false } }

    it "exposes only the four baseline keys on the wire" do
      post "/server_rescue/record_invalid", "{}", function_call_headers
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.keys).to contain_exactly(
        "_ruact_server_action_error",
        "action_name",
        "error_class",
        "message"
      )
    end
  end

  describe "strict-boolean handling for dev_error_payload_enabled — review F3 (A10)" do
    it "non-boolean truthy values fall back to the env default (test env → dev mode)" do
      Ruact.configure { |c| c.dev_error_payload_enabled = "false" }
      post "/server_rescue/record_invalid", "{}", function_call_headers
      body = JSON.parse(last_response.body)
      expect(body).to have_key("app_frames")
      expect(body).to have_key("gem_frames")
      expect(body).to have_key("suggestion")
    end

    it "non-boolean falsy values fall back to the env default (test env → dev mode)" do
      Ruact.configure { |c| c.dev_error_payload_enabled = 0 }
      post "/server_rescue/record_invalid", "{}", function_call_headers
      expect(JSON.parse(last_response.body)).to have_key("app_frames")
    end
  end

  describe "server-side logging always fires (A11)" do
    it "logs the [ruact] error line + backtrace at error severity regardless of wire mode" do
      log_io = StringIO.new
      Rails.logger = Logger.new(log_io)
      post "/server_rescue/runtime_error", "{}", function_call_headers
      expect(last_response.status).to eq(500)
      expect(log_io.string).to include(
        "[ruact] server action :runtime_error failed — RuntimeError: boom"
      )
      expect(log_io.string).to include("server_rescue_request_spec") # a backtrace frame
    end
  end

  describe "CSRF mismatch on a function-call request → 403 + structured payload (A13 / Pitfall #1)" do
    around do |example|
      previous = ServerRescueSpecSupport::ForgeryServerController.allow_forgery_protection
      ServerRescueSpecSupport::ForgeryServerController.allow_forgery_protection = true
      example.run
    ensure
      ServerRescueSpecSupport::ForgeryServerController.allow_forgery_protection = previous
    end

    it "missing X-CSRF-Token produces the structured 403 body with the CSRF suggestion" do
      post "/server_rescue/protected", "{}", function_call_headers
      expect(last_response.status).to eq(403)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("error_class")).to eq("ActionController::InvalidAuthenticityToken")
      expect(body.fetch("suggestion")).to eq(
        "CSRF token mismatch — ensure the page was rendered after the most recent server restart " \
        "and the session cookie is intact"
      )
    end
  end

  describe "AC1 — byte-for-byte: non-function-call requests are untouched (C2/C3/D1)" do
    it "a GET page action renders exactly as without the concern (C2)" do
      get "/server_rescue/page"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("plain page body")
      expect(last_response.headers["Content-Type"]).to include("text/plain")
    end

    it "a raise on a POST without the function-call Accept propagates — no structured swallow (C3)" do
      # show_exceptions = :none on the shared app → Rails' default handling
      # re-raises to the caller, exactly what a vanilla controller does.
      expect do
        post "/server_rescue/runtime_error", "{}", { "CONTENT_TYPE" => "application/json" }
      end.to raise_error(RuntimeError, "boom")
    end

    it "a raise under a browser navigation Accept header also propagates (C3)" do
      expect do
        post "/server_rescue/runtime_error", "{}",
             {
               "CONTENT_TYPE" => "application/json",
               "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
             }
      end.to raise_error(RuntimeError, "boom")
    end

    it "a raise on a GET with Accept: application/json propagates — stock Rails behavior (review patch)" do
      # Function calls are non-GET by the verb rule (epic contract decision
      # #1); a GET carrying a JSON Accept (fetch() to a page action, API
      # probes) must NOT be swallowed into the structured payload.
      expect do
        get "/server_rescue/erroring_page", {}, { "HTTP_ACCEPT" => "application/json" }
      end.to raise_error(RuntimeError, "boom on GET")
    end

    it "a raise on a HEAD with Accept: application/json also propagates (review patch)" do
      expect do
        head "/server_rescue/erroring_page", {}, { "HTTP_ACCEPT" => "application/json" }
      end.to raise_error(RuntimeError, "boom on GET")
    end
  end
end
