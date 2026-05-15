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

# Re-run-5 (2026-05-15) — explicitly require `ruact/railtie` (NOT just
# `ruact`, which is cached as already-loaded by `spec_helper.rb`'s
# earlier `require "ruact"` that ran BEFORE Rails was defined and
# therefore skipped the conditional `require_relative "ruact/railtie"
# if defined?(Rails)` at the bottom of `ruact.rb`). Loading the
# Railtie file directly registers `Ruact::Railtie` with Rails so its
# `routes.prepend` AND `config.to_prepare` initializers (latter wires
# `Ruact::ErbPreprocessorHook` into `ActionView::Template::Handlers::ERB`)
# fire when the test app's `initialize!` runs.
require "ruact/railtie"

# Re-run-2 (2026-05-14): exercise the REAL `ActiveRecord::RecordInvalid`
# rather than a structural stub. ActiveRecord is part of Rails (already a
# dev dep via `gem "rails"`), so requiring `active_model` for the underlying
# validation error and `active_record` for `RecordInvalid` is cheap. The
# require is local to this spec — the rest of the suite continues to use
# the lightweight rails_stub.rb path.
require "active_model"
require "active_record"
require "i18n"

# Load ActiveModel + ActiveRecord locale files so `RecordInvalid#message`
# resolves the `errors.messages.record_invalid` translation key — without
# this, `error.message` returns "Translation missing: en.activemodel.errors..."
# instead of the human-readable "Validation failed: Title can't be blank".
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

# Reuse the Rails::Application booted by `controller_request_spec.rb` if it
# has already been loaded into this RSpec process — Rails does not support
# two distinct `Rails::Application` subclasses initialized in the same
# process (the second `initialize!` raises `FrozenError` on shared internal
# state). When this spec runs alone, build a dedicated minimal app.
require_relative "../controller_request_spec" if defined?(Rails::Application) &&
                                                 !defined?(ControllerRequestSpecSupport)

# Re-run-5 (2026-05-15) — when reusing the Story 7.9 test app, append
# the gem's `POST /__ruact/fn/:name` route AT LOAD TIME (before any
# test runs). This is the only safe window: once `initialize!` has run
# for the app (driven by EITHER spec's first `boot!`), adding routes
# post-finalization is unreliable. Doing it here, at spec file load,
# guarantees the route lands BEFORE either spec calls `boot!`.
if defined?(ControllerRequestSpecSupport)
  ControllerRequestSpecSupport.app_class.routes.append do
    post "/__ruact/fn/:name",
         to: "ruact/server_functions/endpoint#dispatch_action",
         as: :ruact_server_function_spec,
         constraints: { name: /[a-zA-Z_][a-zA-Z0-9_]*/ }
  end
end

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
        # Re-run-5 — when this spec runs standalone (no Story 7.9 app
        # in the process), draw the gem route on its own app BEFORE
        # initialize! so dispatch tests find it.
        app_class.routes.append do
          post "/__ruact/fn/:name",
               to: "ruact/server_functions/endpoint#dispatch_action",
               as: :ruact_server_function_standalone,
               constraints: { name: /[a-zA-Z_][a-zA-Z0-9_]*/ }
        end
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

  # Minimal ActiveModel-compatible record class so a REAL
  # `ActiveRecord::RecordInvalid` instance can be constructed (the error's
  # `#initialize(record)` reads `record.errors.full_messages`). This keeps
  # the AC9 spec faithful to the literal AC wording while not requiring a
  # full ActiveRecord schema/setup.
  class StubPost
    include ActiveModel::Model
    attr_accessor :title
    validates :title, presence: true

    # Override `i18n_scope` to `:activerecord` so `RecordInvalid#message`
    # resolves the `activerecord.errors.messages.record_invalid` key
    # ("Validation failed: %{errors}") instead of falling through to the
    # missing `activemodel.errors.messages.record_invalid`.
    def self.i18n_scope
      :activerecord
    end
  end

  class TestController < ActionController::Base
    include Ruact::Controller

    rescue_from RuntimeError do |error|
      render(json: { error: error.message, error_class: error.class.name }, status: :unprocessable_entity)
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      render(
        json: { error: error.message, error_class: error.class.name, validation: true },
        status: :unprocessable_entity
      )
    end

    before_action :require_token, only: %i[authed_action]

    # Re-run-3 (2026-05-15) — simulates a host before_action that touches
    # `request.body` (e.g., a generic audit/logging filter that reads the
    # raw POST body for signature verification). Pre-batch, `body.read`
    # advanced the IO to EOF, so the action's own `body.read` returned
    # `""` and silently coerced the action call to `{}`. The fix uses
    # `request.raw_post` (Rack-cached) so the action still sees the
    # original body. The `body_peek` action below proves it.
    before_action :peek_body, only: %i[body_peek]
    def peek_body
      @peeked = request.body.read.tap { request.body.rewind if request.body.respond_to?(:rewind) }
    end

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

      ruact_action(:nil_return) { |_p| nil }

      ruact_action(:invalid_record) do |_p|
        record = DispatchRequestSpecSupport::StubPost.new
        record.valid? # populates record.errors
        raise ActiveRecord::RecordInvalid, record
      end

      ruact_action(:body_peek) do |params|
        { "echoed" => params.to_unsafe_h }
      end

      ruact_action(:routing_identity) do |_p|
        # Re-run-2 (2026-05-14) — proves that `params[:controller]` and
        # `params[:action]` inside the host action describe the HOST class,
        # not the gem endpoint route.
        {
          "controller" => self.controller_path,
          "action" => action_name,
          "params_controller" => self.params[:controller],
          "params_action" => self.params[:action]
        }
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

    it "preserves form-encoded body fields named `name`, `action`, `controller` " \
       "(review-batch 2 — drop spurious `.except`)" do
      post "/__ruact/fn/echo", { "name" => "alice", "action" => "submit", "controller" => "foo" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("echoed")).to include(
        "name" => "alice",
        "action" => "submit",
        "controller" => "foo"
      )
    end

    it "returns a structured 400 on malformed JSON instead of silently treating it as {} " \
       "(re-run-4 #1 — structured bad-request response, not raw JSON::ParserError)" do
      # Pre-Re-run-4 this surfaced a raw `JSON::ParserError` from inside
      # the action body. Now `ruact_action`'s defined method catches the
      # parse error and renders a 400 with a `{error}` JSON body — same
      # contract as the unknown-action 404 path.
      post "/__ruact/fn/echo", "{ not json", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to match(/malformed JSON body/)
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
       "`params` accessor carries the routing data (controller/action)" do
      # Re-run-4 (#2): `:name` is no longer injected into
      # `request.path_parameters` (would shadow a legitimate body field
      # named `:name`). The block's `params` is the body; the controller's
      # `params` carries `:controller` and `:action` (Rails routing data).
      post "/__ruact/fn/capture_both",
           { "title" => "From body" }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      body = JSON.parse(last_response.body)
      expect(body.fetch("block_params")).to eq("title" => "From body")
      expect(body.fetch("request_params_name")).to be_nil
    end

    it "preserves a body field literally named `:name` (re-run-4 #2 — no leak from path_parameters)" do
      # Send `{ "name": "alice" }` as the body. Pre-batch the dispatcher
      # had injected `name: "send_name"` into path_parameters which
      # merged into params and shadowed the body field; the block would
      # have seen `params[:name] == "send_name"`. Now it sees "alice".
      post "/__ruact/fn/echo",
           { "name" => "alice" }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("echoed" => { "name" => "alice" })
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

  describe "AC2 — 204 No Content for nil block return (review-batch 1 2026-05-14)" do
    it "renders 204 with empty body when the block returns nil" do
      post "/__ruact/fn/nil_return", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
    end
  end

  describe "AC8 — CSRF contract (review-batch 5 2026-05-14)" do
    # The gem-level endpoint MUST skip forgery protection itself — otherwise
    # the route would reject requests before reaching the host controller
    # that's supposed to be the source of truth for CSRF. The host's
    # `protect_from_forgery` then enforces (or doesn't, in API mode).
    it "EndpointController has removed verify_authenticity_token from its callback chain " \
       "(skip_forgery_protection was applied)" do
      callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
      filter_names = callbacks.map(&:filter)
      expect(filter_names).not_to include(:verify_authenticity_token)
    end

    it "EndpointController inherits from ActionController::Base — runs the full CSRF middleware stack " \
       "on dispatch (allowing the host's protect_from_forgery to take effect)" do
      expect(Ruact::ServerFunctions::EndpointController.ancestors).to include(ActionController::Base)
    end

    # End-to-end CSRF behavior — a host controller with protect_from_forgery
    # rejecting an invalid token — is a Rails-stack integration concern
    # that requires session middleware + a real Rails request cycle with
    # `config.action_controller.allow_forgery_protection = true`. The
    # contract is preserved by virtue of (a) the gem skipping forgery on
    # ITS endpoint and (b) delegating to `host_class.dispatch` which runs
    # the host's own `verify_authenticity_token` filter. Pre-batch-5
    # versions of the story file flagged this as deferred to Story 8.2's
    # `<form action={fn}>` integration where CSRF is the user-visible path.
  end

  describe "Re-run-3 — before_action reads request.body (#3 raw_post fix)" do
    it "the action still sees the original body when a before_action already drained it" do
      # Pre-Re-run-3: the before_action's `body.read` advanced the IO to EOF;
      # the action's own `body.read` returned `""` → `ruact_action_raw_args`
      # silently coerced to `{}` → echoed empty params. Now: `request.raw_post`
      # is Rack-cached, so the action sees the full body.
      post "/__ruact/fn/body_peek", { "title" => "Hello" }.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("echoed" => { "title" => "Hello" })
    end
  end

  describe "Re-run-2 — host routing identity (#6 path params)" do
    it "inside the host action, params[:controller] and params[:action] describe " \
       "the host, not the gem endpoint route" do
      post "/__ruact/fn/routing_identity", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("controller")).to eq("dispatch_request_spec_support/test")
      expect(body.fetch("action")).to eq("routing_identity")
      expect(body.fetch("params_controller")).to eq("dispatch_request_spec_support/test")
      expect(body.fetch("params_action")).to eq("routing_identity")
    end
  end

  describe "Re-run-2 — unknown action returns 404 even when body is malformed (#5)" do
    it "does not parse the body before lookup, so a corrupted JSON for an unknown " \
       "name still returns the 404 shape" do
      # Pre-Re-run-2 this raised ParseError on body parse before the lookup.
      post "/__ruact/fn/no_such_thing", "{ not json", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)).to eq("error" => "unknown ruact action: :no_such_thing")
    end
  end

  describe "AC9 — ActiveRecord::RecordInvalid (re-run-2 #9 — real AR class, not a stub)" do
    it "wraps a real ActiveRecord::RecordInvalid into a structured 422 via the host's rescue_from" do
      post "/__ruact/fn/invalid_record", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("ActiveRecord::RecordInvalid")
      expect(body.fetch("error")).to match(/Title can't be blank/i)
      expect(body.fetch("validation")).to be(true)
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
