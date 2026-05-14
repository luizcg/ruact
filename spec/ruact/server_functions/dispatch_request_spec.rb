# frozen_string_literal: true

# Story 8.1 — full-request-cycle spec covering POST /__ruact/fn/:name dispatch.
#
# Boots a minimal Rails::Application with `Ruact::Railtie` (which mounts the
# `ruact/server_functions/endpoint#dispatch_action` route) and exercises:
#   - Registry lookup (known + unknown name)
#   - JSON request body → `params` shadow inside the block
#   - FormData / urlencoded body → same shadow
#   - host controller's `before_action` chain runs before the block
#   - block return value rendered as JSON
#   - rescue_from on the host controller catches errors raised inside the block
#
# Follows the Story 7.9 pattern (controller_request_spec.rb) — request-cycle
# subsystems are loaded HERE so the rest of the suite continues to use
# spec/support/rails_stub.rb without paying the full Rails boot cost.
require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"
require "rack/test"

require "ruact/controller"
require "ruact/server_functions/endpoint_controller"

# Reuse the Rails::Application booted by `controller_request_spec.rb` if it
# has already been loaded into this RSpec process — Rails does not support
# two distinct `Rails::Application` subclasses initialized in the same
# process (the second `initialize!` raises `FrozenError` on shared internal
# state). When this spec runs alone, build a dedicated minimal app.
require_relative "../controller_request_spec" if defined?(Rails::Application) &&
                                                 !defined?(ControllerRequestSpecSupport)

module DispatchRequestSpecSupport
  class << self
    def app_class
      @app_class ||=
        if defined?(ControllerRequestSpecSupport)
          ControllerRequestSpecSupport.app_class
        else
          build_app_class
        end
    end

    def boot!
      return if @booted
      if defined?(ControllerRequestSpecSupport)
        ControllerRequestSpecSupport.boot!
      else
        app_class.instance.initialize!
      end
      @booted = true
    end

    private

    def build_app_class
      Class.new(Rails::Application) do
        config.eager_load                        = false
        config.consider_all_requests_local       = true
        config.action_controller.perform_caching = false
        config.action_dispatch.show_exceptions   = :none
        config.logger                            = Logger.new(IO::NULL)
        config.active_support.deprecation        = :silence
        config.secret_key_base                   = "x" * 64
        config.hosts.clear if config.respond_to?(:hosts)
      end
    end
  end

  class TestController < ActionController::Base
    include Ruact::Controller

    rescue_from RuntimeError do |error|
      render(json: { error: error.message, error_class: error.class.name }, status: :unprocessable_entity)
    end

    before_action :require_token, only: %i[__ruact_action_authed_action]

    # spec_helper wipes the registries between examples (lazy-init singletons
    # reset to fresh instances), so the controller's class-body `ruact_action`
    # declarations would only populate the original singleton — invisible to
    # the new one a subsequent example sees. Re-register at the start of every
    # example via this class method instead.
    def self.register_ruact_actions!
      ruact_action(:echo) { |params| { "echoed" => params.to_unsafe_h } }

      ruact_action(:fail_hard) { |_params| raise "intentional failure" }

      ruact_action(:authed_action) { |params| { "ok" => true, "by" => params[:by] } }

      ruact_action(:capture_both) do |params|
        {
          "block_params" => params.to_unsafe_h,
          "request_params_name" => self.params[:name]
        }
      end

      ruact_action(:strong_params_demo) do |params|
        permitted = params.require(:post).permit(:title, :body)
        { "permitted" => permitted.to_h }
      end
    end

    private

    def require_token
      return if request.headers["X-Test-Token"] == "secret"
      render(json: { error: "unauthorized" }, status: :unauthorized)
    end
  end
end

Rails.application = nil if Rails.respond_to?(:application) && !Rails.application.is_a?(Rails::Application)

RSpec.describe "Story 8.1: POST /__ruact/fn/:name dispatch", :story_8_1 do
  include Rack::Test::Methods

  let(:app_class) { DispatchRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  before do
    Rails.logger = Logger.new(IO::NULL)
    DispatchRequestSpecSupport.boot!
    # spec_helper resets the registry singletons between examples — re-register
    # so the endpoint controller can resolve the test action names. (Production
    # gets re-registrations naturally from class-body evaluation at controller
    # autoload; the test environment short-circuits that.)
    DispatchRequestSpecSupport::TestController.register_ruact_actions!
  end

  describe "AC2 — happy-path dispatch" do
    it "dispatches a registered action with JSON body and returns the block's return value as JSON" do
      post "/__ruact/fn/echo", { "title" => "Hi" }.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(JSON.parse(last_response.body)).to eq("echoed" => { "title" => "Hi" })
    end

    it "returns 404 with a structured error for an unknown action name" do
      post "/__ruact/fn/no_such_thing", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)).to eq("error" => "unknown ruact action: :no_such_thing")
    end

    it "accepts form-encoded request bodies (FormData / urlencoded)" do
      post "/__ruact/fn/echo", { "title" => "From form" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("echoed")).to include("title" => "From form")
    end

    it "treats an empty request body as an empty params hash" do
      post "/__ruact/fn/echo", "", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("echoed" => {})
    end
  end

  describe "AC3 — before_action chain runs before the block" do
    it "the host's before_action short-circuits without ever executing the block" do
      post "/__ruact/fn/authed_action",
           { "by" => "alice" }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)).to eq("error" => "unauthorized")
    end

    it "the block runs only when the before_action passes" do
      post "/__ruact/fn/authed_action",
           { "by" => "alice" }.to_json,
           { "CONTENT_TYPE" => "application/json", "HTTP_X_TEST_TOKEN" => "secret" }
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("ok" => true, "by" => "alice")
    end
  end

  describe "AC5 — params shadow inside the block" do
    it "the block's `params` argument carries the action-call args; the controller's " \
       "`params` accessor still carries the routing data (`:name`)" do
      post "/__ruact/fn/capture_both",
           { "title" => "From body" }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      body = JSON.parse(last_response.body)
      expect(body.fetch("block_params")).to eq("title" => "From body")
      expect(body.fetch("request_params_name")).to eq("capture_both")
    end
  end

  describe "AC3 — rescue_from on host controller catches block errors" do
    it "wraps a block-raised RuntimeError into a structured 422 via the host's rescue_from" do
      post "/__ruact/fn/fail_hard", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body).to eq("error" => "intentional failure", "error_class" => "RuntimeError")
    end
  end

  describe "Task 5.4 — strong-parameters API works on the shadowed `params`" do
    it "params.require(:post).permit(:title, :body) returns the permitted hash" do
      post "/__ruact/fn/strong_params_demo",
           { "post" => { "title" => "Hi", "body" => "Body", "evil" => "ignored" } }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("permitted")).to eq("title" => "Hi", "body" => "Body")
    end

    it "params.require(:post) raises ParameterMissing when the key is absent (proves shadow works)" do
      # Rails app has `show_exceptions: :none`, so the exception bubbles up to
      # Rack — the request raises directly rather than being converted to a
      # 400 response. Asserting the raise is a stronger guarantee than the
      # status code: the call truly reaches `params.require(:post)` inside
      # the block and the shadowed `params` IS an `ActionController::Parameters`.
      expect do
        post "/__ruact/fn/strong_params_demo", "{}", { "CONTENT_TYPE" => "application/json" }
      end.to raise_error(ActionController::ParameterMissing, /param is missing.*post/)
    end
  end
end
