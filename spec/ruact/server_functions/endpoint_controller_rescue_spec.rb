# frozen_string_literal: true

# Story 8.4 — Cross-branch rescue_from coverage for
# `Ruact::ServerFunctions::EndpointController`. Exercises:
#
#   - controller-hosted dispatch where the HOST has no `rescue_from`
#     → endpoint's `rescue_from StandardError` catches and renders the
#     structured payload (AC1, AC2)
#   - controller-hosted dispatch where the HOST has its OWN `rescue_from`
#     for the same class → host wins (AC1 host-precedence invariant)
#   - standalone-hosted dispatch where the block raises a non-`ActionError`
#     → same structured payload (AC1 standalone branch)
#   - production-mode payload reduction (AC2, AC6 wire shape)
#
# Mounts on the shared Rails app booted by `controller_request_spec.rb`
# (the same app `dispatch_request_spec.rb` uses) — only one
# `Rails::Application` is allowed per process, so this file piggybacks on
# the already-loaded boot scaffolding.

require "spec_helper"
require "rack/test"

require "action_controller/railtie"
require "action_view/railtie"

require "ruact/controller"
require "ruact/server_functions/endpoint_controller"
require "ruact/server_action"
require "ruact/railtie"

require "active_model"
require "active_record"
require "i18n"

# Reuse the locale loader pattern from dispatch_request_spec.rb so
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

# Review F4 — gate dependency loads on the CONSTANT (`ControllerRequestSpecSupport`
# / `DispatchRequestSpecSupport`) rather than on `defined?(Rails::Application)`
# + the constant. Rails::Application is already defined by the railtie requires
# above, so the original conjunction effectively reduced to the constant
# check; using only the constant makes the intent explicit and matches how
# `dispatch_request_spec.rb` guards its own controller_request_spec load.
#
# Critically, the conditional MUST stay: RSpec loads top-level spec files via
# `Kernel.load`, which does NOT populate `$LOADED_FEATURES`. An unconditional
# `require_relative` here would re-execute the file's top-level
# `routes.append` block, producing an `ArgumentError: Invalid route name,
# already in use` when both this file and `dispatch_request_spec.rb` are in
# the same RSpec invocation. The constant check is the safe dedupe.
require_relative "../controller_request_spec" unless defined?(ControllerRequestSpecSupport)
require_relative "dispatch_request_spec"      unless defined?(DispatchRequestSpecSupport)

module Story84RescueSpecSupport
  # Lightweight ActiveModel-shaped class so we can construct a REAL
  # `ActiveRecord::RecordInvalid` instance.
  class Story84Post
    include ActiveModel::Model

    attr_accessor :title

    validates :title, presence: true

    def self.i18n_scope
      :activerecord
    end
  end

  # Host controller with NO rescue_from chain — exceptions bubble all the
  # way up to the endpoint controller's `rescue_from StandardError` so the
  # gem's structured handler fires.
  class BareHostController < ActionController::Base
    include Ruact::Controller

    def self.register_ruact_actions!
      ruact_action(:bare_record_invalid) do |_params|
        record = Story84RescueSpecSupport::Story84Post.new
        record.valid? # populates record.errors
        raise ActiveRecord::RecordInvalid, record
      end

      ruact_action(:bare_argument_error) { |_params| raise ArgumentError, "bad arg" }

      ruact_action(:bare_runtime_error)  { |_params| raise "boom" }
    end
  end

  # Host controller that catches RecordInvalid itself — proves the
  # endpoint's `rescue_from` does NOT preempt a host's chain.
  class CaughtHostController < ActionController::Base
    include Ruact::Controller

    rescue_from ActiveRecord::RecordInvalid do |error|
      render(
        json: { caught_by_host: true, error_class: error.class.name },
        status: :unprocessable_entity
      )
    end

    def self.register_ruact_actions!
      ruact_action(:caught_record_invalid) do |_params|
        record = Story84RescueSpecSupport::Story84Post.new
        record.valid?
        raise ActiveRecord::RecordInvalid, record
      end
    end
  end

  module StandaloneHost
    extend Ruact::ServerAction unless singleton_class.include?(Ruact::ServerAction)

    def self.register!
      ruact_action(:standalone_record_invalid) do |_params|
        record = Story84RescueSpecSupport::Story84Post.new
        record.valid?
        raise ActiveRecord::RecordInvalid, record
      end

      ruact_action(:standalone_runtime) { |_params| raise "standalone boom" }
    end
  end
end

RSpec.describe "Story 8.4: EndpointController rescue_from chain", :story_8_4 do
  include Rack::Test::Methods

  let(:app_class) { DispatchRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  before do
    Rails.logger = Logger.new(IO::NULL)
    DispatchRequestSpecSupport.boot!
    Story84RescueSpecSupport::BareHostController.register_ruact_actions!
    Story84RescueSpecSupport::CaughtHostController.register_ruact_actions!
    Story84RescueSpecSupport::StandaloneHost.register!
  end

  describe "AC1 — controller-hosted: host has no rescue_from → gem catches" do
    it "RecordInvalid bubbled past a bare host renders 422 + structured payload (dev mode)" do
      post "/__ruact/fn/bare_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body).to include(
        "_ruact_server_action_error" => true,
        "action_name" => "bare_record_invalid",
        "error_class" => "ActiveRecord::RecordInvalid"
      )
      expect(body.fetch("message")).to match(/Title can't be blank/)
      expect(body.fetch("validation_errors")).to include(/Title can't be blank/)
      expect(body.fetch("suggestion")).to eq("Validation failed — check the model's `validates` rules")
      expect(body).to have_key("app_frames")
      expect(body).to have_key("gem_frames")
    end

    it "ArgumentError bubbled past a bare host renders 500 + structured payload" do
      post "/__ruact/fn/bare_argument_error", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("action_name")).to eq("bare_argument_error")
      expect(body.fetch("error_class")).to eq("ArgumentError")
      expect(body.fetch("message")).to eq("bad arg")
      expect(body.fetch("suggestion")).to be_nil
    end

    it "RuntimeError bubbled past a bare host renders 500 + structured payload" do
      post "/__ruact/fn/bare_runtime_error", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("RuntimeError")
      expect(body.fetch("message")).to eq("boom")
    end
  end

  describe "AC1 — controller-hosted: host has its own rescue_from → host wins" do
    it "RecordInvalid handled by the host renders the host's body, NOT the structured payload" do
      post "/__ruact/fn/caught_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("caught_by_host")).to be(true)
      expect(body).not_to have_key("_ruact_server_action_error")
    end
  end

  describe "AC1 — standalone branch: block raise produces structured payload" do
    around do |example|
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    it "standalone RecordInvalid renders 422 + structured payload" do
      post "/__ruact/fn/standalone_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("action_name")).to eq("standalone_record_invalid")
      expect(body.fetch("error_class")).to eq("ActiveRecord::RecordInvalid")
      expect(body.fetch("suggestion")).to eq("Validation failed — check the model's `validates` rules")
    end

    it "standalone RuntimeError renders 500 + structured payload" do
      post "/__ruact/fn/standalone_runtime", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("RuntimeError")
    end
  end

  describe "AC2 / AC6 — production-mode payload reduction" do
    # Configure in a `before` hook so the spec_helper's @config reset
    # (which runs in `config.before`) fires FIRST; configuring inside
    # `around` would be wiped out before the example body runs.
    before { Ruact.configure { |c| c.dev_error_payload_enabled = false } }

    it "exposes only the four baseline keys on the wire" do
      post "/__ruact/fn/bare_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
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

  # Review follow-up — review F3: only the strict booleans `true` / `false`
  # count as an explicit configuration; any other value falls back to the env
  # default rather than being coerced via Ruby truthiness. Without strict
  # handling, a misconfigured `c.dev_error_payload_enabled = "false"` (a
  # string) would be truthy → enabled → leak the verbose payload in
  # production.
  describe "Review F3 — strict-boolean handling for dev_error_payload_enabled" do
    it "non-boolean truthy values fall back to the env default (test env → dev mode)" do
      Ruact.configure { |c| c.dev_error_payload_enabled = "false" }
      post "/__ruact/fn/bare_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      # The string "false" is NOT coerced as false; the fallback (Rails.env
      # test → dev) wins, so the verbose payload keys are present.
      expect(body).to have_key("app_frames")
      expect(body).to have_key("gem_frames")
      expect(body).to have_key("suggestion")
    end

    it "non-boolean falsy values fall back to the env default (test env → dev mode)" do
      Ruact.configure { |c| c.dev_error_payload_enabled = 0 }
      post "/__ruact/fn/bare_record_invalid", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body).to have_key("app_frames")
    end
  end

  describe "AC3 — CSRF mismatch on a standalone action → 403 + structured payload with suggestion" do
    around do |example|
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = true
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    it "missing X-CSRF-Token on a standalone POST produces the structured 403 body " \
       "(Pitfall #1: gem's explicit rescue_from preempts Rails' handle_unverified_request)" do
      # Multipart body matches the runtime's `<form action={fn}>` wire shape.
      boundary = "----RuactSpec84#{SecureRandom.hex(4)}"
      body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--#{boundary}--\r\n"
      post "/__ruact/fn/standalone_record_invalid", body,
           "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
           "CONTENT_LENGTH" => body.bytesize.to_s

      expect(last_response.status).to eq(403)
      parsed = JSON.parse(last_response.body)
      expect(parsed.fetch("_ruact_server_action_error")).to be(true)
      expect(parsed.fetch("error_class")).to eq("ActionController::InvalidAuthenticityToken")
      expect(parsed.fetch("suggestion")).to eq(
        "CSRF token mismatch — ensure the page was rendered after the most recent server restart and the session cookie is intact"
      )
    end
  end
end
