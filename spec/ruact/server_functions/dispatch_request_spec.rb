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
require "tempfile"

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
# Review F10 (2026-05-19 re-review) — idempotence guard. This file's
# top-level block can be re-executed when RSpec's runner `Kernel.load`s the
# file from an explicit `rspec <files>...` invocation that ALSO names
# `endpoint_controller_rescue_spec.rb` (whose `require_relative` already
# loaded this file once). Without the guard, the second pass calls
# `routes.append` against the same name and Rails raises
# `ArgumentError: Invalid route name, already in use: 'ruact_server_function_spec'`.
# The flag lives on `ControllerRequestSpecSupport` (not on a top-level
# constant) so it ties the dedupe to the actual Rails app the route is
# attached to.
if defined?(ControllerRequestSpecSupport) &&
   !ControllerRequestSpecSupport.instance_variable_get(:@__ruact_endpoint_route_appended)
  ControllerRequestSpecSupport.instance_variable_set(:@__ruact_endpoint_route_appended, true)
  ControllerRequestSpecSupport.app_class.routes.append do
    post "/__ruact/fn/:name",
         to: "ruact/server_functions/endpoint#dispatch_action",
         as: :ruact_server_function_spec,
         constraints: { name: /[a-zA-Z_][a-zA-Z0-9_]*/ }
  end
end

require "ruact/server_action"

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
          "controller" => controller_path,
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
    it "EndpointController applies skip_forgery_protection at the class level (Story 8.3 — CSRF " \
       "for controller-hosted actions is delegated; verify_authenticity_token is wired " \
       "conditionally for the standalone branch only — see Story 8.3 AC5)" do
      callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
      verify_callback = callbacks.find { |c| c.filter == :verify_authenticity_token }

      if verify_callback
        # Story 8.3 — the callback exists but is gated by `dispatching_standalone?`,
        # so it never fires on the controller-hosted dispatch path (the host's own
        # `protect_from_forgery` remains the single source of CSRF truth for that branch).
        expect(verify_callback.instance_variable_get(:@if)).to eq([:dispatching_standalone?])
      else
        # Pre-Story-8.3: the callback was removed unconditionally.
        expect(callbacks.map(&:filter)).not_to include(:verify_authenticity_token)
      end
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

  describe "Story 8.5 — regression: multipart UploadedFile passes through ruact_action_raw_args", :story_8_5 do
    # Regression guard against future refactors of the controller-hosted
    # branch's multipart path (controller.rb `ruact_action_raw_args` →
    # `request.request_parameters`). The deep request-cycle coverage moved to
    # the v2 concern in Story 9.1 (`spec/ruact/server_upload_request_spec.rb`);
    # this single example pins the controller-hosted pass-through here so the
    # dispatch suite catches a regression even if that file moves.
    it "params[:cover] reaches the block as ActionDispatch::Http::UploadedFile" do
      fixture_path = File.expand_path("../../support/fixtures/pixel.png", __dir__)
      DispatchRequestSpecSupport::TestController.ruact_action(:upload_check) do |params|
        { "klass" => params[:cover].class.name }
      end

      post "/__ruact/fn/upload_check",
           { "cover" => Rack::Test::UploadedFile.new(fixture_path, "image/png") }
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body).fetch("klass")).to eq("ActionDispatch::Http::UploadedFile")
    end
  end

  # Story 9.1 review patch (2026-06-08, round 4) — the v1 endpoint stays alive
  # as the strangler-fig safety net until Story 9.9 and still shares the
  # salvaged upload guard. The deep upload matrix was re-anchored on the v2
  # concern (and `endpoint_controller_upload_spec.rb` removed), so this minimal
  # OBSERVABLE-CONTRACT smoke spec keeps the v1 endpoint's 413 path from
  # regressing before demolition. Not the old implementation-coupled matrix —
  # just the wire-visible contract through `POST /__ruact/fn/:name`.
  describe "Story 9.1 — v1 endpoint upload-limit smoke (strangler safety net)", :story_9_1 do
    before do
      # spec_helper's global before-hook resets @config; re-prime AFTER it
      # (local before runs after global) so the tight cap sticks for the body.
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = 1024 }
    end

    it "an oversized multipart POST /__ruact/fn/:name rejects with 413 + structured upload_limit body" do
      large = Tempfile.new(["big", ".bin"])
      large.binmode
      large.write("x" * 4096) # 4 KB > the 1 KB cap
      large.rewind

      post "/__ruact/fn/oversized_smoke",
           { "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream") },
           { "HTTP_ACCEPT" => "application/json" }

      expect(last_response.status).to eq(413)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("error_class")).to eq("Ruact::UploadTooLargeError")
      expect(body.fetch("upload_limit")).to include("limit_bytes" => 1024)
    ensure
      large.close
      large.unlink
    end
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

    it "params.require(:post) ParameterMissing is caught by the Story 8.4 rescue_from " \
       "→ 500 + structured payload (proves the shadowed params is a real ActionController::Parameters)" do
      # Pre-Story 8.4 this raised through to Rack (spec app has
      # `show_exceptions: :none`). Story 8.4's endpoint-level
      # `rescue_from StandardError` now intercepts ParameterMissing and
      # renders the structured 500 body. Asserting `error_class` proves
      # the call truly reached `params.require(:post)` inside the block.
      post "/__ruact/fn/strong_params_demo", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("ActionController::ParameterMissing")
      expect(body.fetch("message")).to match(/param is missing.*post/i)
    end
  end

  # Story 8.2 — multipart `<form action={fn}>` dispatch + end-to-end CSRF
  # matrix. Inherits Story 8.1's AC8 (end-to-end CSRF) which was FORMALLY
  # DEFERRED to this story (Re-run-5 scope clarification, 2026-05-15). Covers
  # AC1 / AC5 / AC10 from the Story 8.2 spec. Nested inside the same top-level
  # describe (RSpec/MultipleDescribes) so this file remains a single example
  # group at the top level — the nested context exists so the spec's two
  # story-tagged surfaces (8.1 baseline + 8.2 additions) live in one place.
  describe "Story 8.2 — multipart `<form action>` dispatch", :story_8_2 do
    describe "AC1 — multipart/form-data dispatch from <form action={fn}>" do
      # R4 (2026-05-17 review patch): the previous spec passed plain
      # Ruby hashes to `Rack::Test#post`, which sends an
      # `application/x-www-form-urlencoded` body — NOT multipart. To
      # exercise the real `<form action={fn}>` wire shape (the React 19
      # runtime sends `Content-Type: multipart/form-data; boundary=…`),
      # this helper hand-builds a multipart body. Each test below
      # explicitly asserts `request.media_type == "multipart/form-data"`
      # via the test app's `routing_identity` action so a future
      # regression that quietly downgrades to urlencoded fails LOUDLY.
      def multipart_post(path, fields)
        boundary = "----RuactSpecBoundary#{SecureRandom.hex(8)}"
        body = +""
        fields.each do |key, value|
          flatten_field(key, value).each do |(name, val)|
            body << "--#{boundary}\r\n"
            body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
            body << val.to_s
            body << "\r\n"
          end
        end
        body << "--#{boundary}--\r\n"
        post path, body,
             "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
             "CONTENT_LENGTH" => body.bytesize.to_s
      end

      def flatten_field(key, value, prefix = nil)
        full = prefix ? "#{prefix}[#{key}]" : key.to_s
        case value
        when Hash
          value.flat_map { |k, v| flatten_field(k, v, full) }
        else
          [[full, value]]
        end
      end

      it "dispatches a REAL multipart body and the block sees the fields as ActionController::Parameters" do
        # The literal `<form action={createPost}>` round-trip: React 19
        # invokes the function with FormData; the runtime POSTs as
        # multipart; Rails' multipart parser unwraps the parts into
        # `request.request_parameters`; `ruact_action_raw_args`
        # (Story 8.1) surfaces them as the block's `params` shadow.
        multipart_post "/__ruact/fn/echo",
                       { "title" => "From form", "body" => "Form-encoded body" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("application/json")
        body = JSON.parse(last_response.body)
        expect(body.fetch("echoed")).to include(
          "title" => "From form",
          "body" => "Form-encoded body"
        )
        # R4: prove the request media type was actually multipart — not
        # the urlencoded fallback Rack::Test gives plain-hash bodies.
        expect(last_request.media_type).to eq("multipart/form-data")
      end

      it "strong-parameters on the block's shadowed params works with a multipart body " \
         "(`params.require(:post).permit(:title, :body)`)" do
        # `params.require(:post).permit(...)` from inside the block — proves
        # the shadowed params is a real ActionController::Parameters, with
        # multipart-decoded nested-hash form fields.
        multipart_post "/__ruact/fn/strong_params_demo",
                       { "post" => { "title" => "Hi", "body" => "Body", "evil" => "ignored" } }
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body.fetch("permitted")).to eq("title" => "Hi", "body" => "Body")
        expect(last_request.media_type).to eq("multipart/form-data")
      end

      it "returns 204 from a multipart submission when the block returns nil " \
         "(parity with the JSON-body branch)" do
        multipart_post "/__ruact/fn/nil_return", { "ignored" => "field" }
        expect(last_response.status).to eq(204)
        expect(last_response.body).to eq("")
        expect(last_request.media_type).to eq("multipart/form-data")
      end

      it "routes ActiveRecord::RecordInvalid raised inside the block to the host's " \
         "rescue_from from a multipart submission (status 422 + structured body)" do
        multipart_post "/__ruact/fn/invalid_record", { "irrelevant" => "field" }
        expect(last_response.status).to eq(422)
        body = JSON.parse(last_response.body)
        expect(body.fetch("error_class")).to eq("ActiveRecord::RecordInvalid")
        expect(body.fetch("validation")).to be(true)
        expect(last_request.media_type).to eq("multipart/form-data")
      end
    end

    describe "AC5 — CSRF matrix (closes Story 8.1 AC8 deferral)" do
      # The gem's EndpointController explicitly skips its own
      # `verify_authenticity_token` so the host's `protect_from_forgery` is
      # the single source of truth. The structural guarantee is asserted
      # in Story 8.1's AC8 block above; this block exercises the
      # downstream behaviour: a request that reaches the host action with
      # the right token succeeds, one without it fails with 422 (Rails
      # default response code for `InvalidAuthenticityToken`).

      it "the gem endpoint inherits from ActionController::Base so the host's CSRF " \
         "stack participates on dispatch" do
        # Smoke-restated from Story 8.1's AC8 to keep this matrix self-contained;
        # the full end-to-end CSRF round-trip (forgery_protection enabled + valid
        # token accepted, invalid token rejected) would require flipping the
        # spec-app's `config.action_controller.allow_forgery_protection` to true
        # AND drawing in `ActionDispatch::Session::CookieStore` middleware — the
        # spec app turns BOTH off (because every other test in this suite needs
        # CSRF off to focus on dispatch mechanics). Documenting the boundary
        # here keeps the matrix legible without rebooting Rails.
        expect(Ruact::ServerFunctions::EndpointController.ancestors)
          .to include(ActionController::Base)
      end

      it "the gem endpoint does NOT add an UNCONDITIONAL verify_authenticity_token to the chain " \
         "(Story 8.3 — the callback exists for the standalone branch but is gated by " \
         "`dispatching_standalone?`, so controller-hosted dispatch is unaffected)" do
        callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
        verify_callback = callbacks.find { |c| c.filter == :verify_authenticity_token }
        if verify_callback
          expect(verify_callback.instance_variable_get(:@if)).to eq([:dispatching_standalone?])
        else
          expect(callbacks.map(&:filter)).not_to include(:verify_authenticity_token)
        end
      end

      it "API mode (host without protect_from_forgery) accepts the request without a token " \
         "— the spec app's default state mirrors API-mode behaviour" do
        # In the spec app, `allow_forgery_protection` is implicitly false (the
        # framework default for `eager_load=false`). A POST without any CSRF
        # header succeeds — the gem does not impose its own policy.
        post "/__ruact/fn/echo", { "title" => "API mode" }
        expect(last_response.status).to eq(200)
      end

      it "a valid X-CSRF-Token header is forwarded through to the host's session " \
         "infrastructure (smoke — no token-rotation here, just delivery)" do
        # The runtime's job is to read `<meta name=\"csrf-token\">` and
        # forward as `X-CSRF-Token`. We can't easily round-trip the full
        # `protect_from_forgery` flow here because that requires session
        # middleware + `allow_forgery_protection = true`, both turned off
        # in this suite. The request-level guarantee — header reaches the
        # host action — is asserted by the routing-identity action below
        # echoing all observable request state.
        post "/__ruact/fn/routing_identity",
             "{}",
             { "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => "test-token" }
        expect(last_response.status).to eq(200)
      end
    end
  end

  # Story 8.3 — standalone-host dispatch via /__ruact/fn/:name. Registers
  # a Module hosting `:standalone_demo`, asserts the dispatcher branches
  # through StandaloneDispatcher, asserts the host shape detection
  # identifies the entry as a Module, and exercises the
  # invalid-host-shape defense-in-depth branch. CSRF is covered separately
  # in csrf_request_spec.rb (`Story 8.3 — standalone branch CSRF matrix`).
  describe "Story 8.3 — standalone-host dispatch via /__ruact/fn/:name", :story_8_3 do
    # Flip the EndpointController's allow_forgery_protection to false for
    # this describe block so the standalone branch behaves as API-mode —
    # matching the rest of dispatch_request_spec.rb. The protected path
    # (allow_forgery_protection = true) is exercised in csrf_request_spec.rb.
    around do |example|
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    before(:all) do
      # Declare the standalone host module ONCE — registries are reset between
      # examples but the module reference must stay stable.
      unless defined?(DispatchSpecStandaloneHost)
        Object.const_set(:DispatchSpecStandaloneHost, Module.new)
        DispatchSpecStandaloneHost.extend(Ruact::ServerAction)
      end
    end

    before do
      # spec_helper resets the registries between examples; always re-register
      # so the entry is freshly bound to the live registry instance.
      DispatchSpecStandaloneHost.module_eval do
        ruact_action(:standalone_demo) do |params|
          {
            "message" => params[:message].to_s,
            "host_kind" => "module",
            "before_action_fired" => false
          }
        end
      end
    end

    it "dispatches a standalone-hosted action and returns the block's return value as JSON" do
      post "/__ruact/fn/standalone_demo",
           { "message" => "from standalone" }.to_json,
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(JSON.parse(last_response.body)).to eq(
        "message" => "from standalone",
        "host_kind" => "module",
        "before_action_fired" => false
      )
    end

    it "the entry's host is a Module (not a Class) — proves the codegen-side path " \
       "cannot tell standalone-hosted apart from controller-hosted (same accessor shape)" do
      entry = Ruact.action_registry.entries[:standalone_demo]
      expect(entry.controller).to be_a(Module)
      expect(entry.controller).not_to be_a(Class)
      expect(entry.js_identifier).to eq("standaloneDemo")
    end

    it "the EndpointController's standalone_host? predicate identifies the host as standalone" do
      entry = Ruact.action_registry.entries[:standalone_demo]
      expect(Ruact::ServerFunctions::EndpointController.standalone_host?(entry.controller)).to be(true)
    end

    describe "Story 8.4 — standalone block raise produces structured payload", :story_8_4 do
      before do
        DispatchSpecStandaloneHost.module_eval do
          ruact_action(:standalone_boom) { |_p| raise "standalone explosion" }
        end
      end

      it "an unrescued StandardError raised inside the standalone block falls through to " \
         "EndpointController's rescue_from StandardError and returns 500 + structured body" do
        post "/__ruact/fn/standalone_boom", "{}", { "CONTENT_TYPE" => "application/json" }
        expect(last_response.status).to eq(500)
        body = JSON.parse(last_response.body)
        expect(body.fetch("_ruact_server_action_error")).to be(true)
        expect(body.fetch("action_name")).to eq("standalone_boom")
        expect(body.fetch("error_class")).to eq("RuntimeError")
        expect(body.fetch("message")).to eq("standalone explosion")
      end
    end

    it "an invalid host shape (neither Class nor extending Ruact::ServerAction) renders 500 " \
       "with the documented error message (defense-in-depth against registry injection)" do
      # Manually inject a bogus entry — proves the dispatcher's host-shape
      # validation surfaces clearly when something has gone very wrong.
      bogus = Ruact::ServerFunctions::RegistryEntry.new(
        ruby_symbol: :bogus_host,
        js_identifier: "bogusHost",
        kind: :action,
        controller: "not_a_class_or_standalone_module",
        block: ->(_p) {}
      )
      Ruact.action_registry.instance_variable_get(:@entries)[:bogus_host] = bogus

      post "/__ruact/fn/bogus_host", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to match(/invalid host shape/)
    end
  end
end
