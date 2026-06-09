# frozen_string_literal: true

# Story 9.2 — request-cycle spec for dual-bucket response negotiation on the
# SAME controller action, on the `Ruact::Server` concern. Pins, against REAL
# host-controller routes:
#
#   - Bucket 2 (Accept: application/json, non-GET) normal completion → JSON of
#     all exposed ivars keyed by name, via ruact_props/Serializable (AC2)
#   - Bucket 2 redirect_to → { "$redirect": "<path>" } (AC3)
#   - Bucket 2 empty → 204, no body (AC4)
#   - Bucket 2 serialization failure → 9.1 chain → 500 structured (AC5)
#   - Vary: Accept on EVERY non-GET shape — 200 / 204 / $redirect / Flight (AC6)
#   - CSRF on Bucket 2 — host protect_from_forgery (AC7)
#   - Bucket 1 (text/x-component) redirect → Flight redirect row, unchanged (AC1)
#
# Mounts on the shared Story-7.9 Rails app; mirrors the 9.1 request-spec pattern.

require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"
require "rack/test"

require "ruact/controller"
require "ruact/server"

require_relative "controller_request_spec" unless defined?(ControllerRequestSpecSupport)

module ServerBucketSpecSupport
  # Serializable model — only :id/:title exposed; :secret must never leak.
  class BucketPost
    include Ruact::Serializable

    attr_reader :id, :title, :secret

    def initialize(id:, title:, secret:)
      @id = id
      @title = title
      @secret = secret
    end

    ruact_props :id, :title
  end

  # Non-Serializable record with as_json — under strict_serialization it must
  # raise Ruact::SerializationError (AC5).
  class UnserializableRecord
    def as_json(_opts = nil)
      { "id" => 1, "leak" => "everything" }
    end
  end

  # Bucket-2 host: includes ONLY Ruact::Server (Bucket-2 requests are handled
  # by Server#default_render without delegating to Ruact::Controller).
  class BucketServerController < ActionController::Base
    include Ruact::Server

    def with_ivars
      @post = BucketPost.new(id: 1, title: "Hi", secret: "topsecret")
      @count = 2
      # no explicit render → default_render
    end

    def empty_action
      # sets no exposed ivars, no redirect → 204 on Bucket 2
    end

    def redirecting
      redirect_to "/posts/1"
    end

    # Review round 1 — cross-host redirect must hit Rails' open-redirect
    # protection (raise) instead of silently emitting an external $redirect.
    def redirect_external
      redirect_to "https://evil.example.com/x"
    end

    def redirect_external_allowed
      redirect_to "https://allowed.example.com/x", allow_other_host: true
    end

    # Review round 1 — a host that sets Vary itself must keep it; Accept is
    # appended, not clobbered.
    def vary_clobber
      response.headers["Vary"] = "Cookie"
      @ok = true
    end

    def unserializable
      @rec = UnserializableRecord.new
    end
  end

  # Bucket-1 regression host: BOTH concerns, so a non-function-call request
  # delegates Server#redirect_to → super → Ruact::Controller's Flight row.
  class BucketDualController < ActionController::Base
    include Ruact::Controller
    include Ruact::Server

    def redirecting
      redirect_to "/posts/1"
    end
  end

  # CSRF-enforcing Bucket-2 host (AC7) — forgery flipped on per-example.
  class BucketForgeryController < ActionController::Base
    include Ruact::Server

    protect_from_forgery with: :exception

    def create_protected
      @ok = true
    end

    # GET is exempt from CSRF verification — emits a per-request token masked
    # against the session master, for the valid-token round-trip (AC7).
    def csrf_token
      render json: { token: form_authenticity_token }
    end
  end
end

if defined?(ControllerRequestSpecSupport) &&
   !ControllerRequestSpecSupport.instance_variable_get(:@__ruact_server_bucket_routes_appended)
  ControllerRequestSpecSupport.instance_variable_set(:@__ruact_server_bucket_routes_appended, true)
  ControllerRequestSpecSupport.app_class.routes.append do
    post "/bucket/with_ivars",      to: "server_bucket_spec_support/bucket_server#with_ivars"
    post "/bucket/empty",           to: "server_bucket_spec_support/bucket_server#empty_action"
    post "/bucket/redirecting",     to: "server_bucket_spec_support/bucket_server#redirecting"
    post "/bucket/redirect_external", to: "server_bucket_spec_support/bucket_server#redirect_external"
    post "/bucket/redirect_external_allowed", to: "server_bucket_spec_support/bucket_server#redirect_external_allowed"
    post "/bucket/vary_clobber",    to: "server_bucket_spec_support/bucket_server#vary_clobber"
    post "/bucket/unserializable",  to: "server_bucket_spec_support/bucket_server#unserializable"
    post "/bucket/dual_redirecting", to: "server_bucket_spec_support/bucket_dual#redirecting"
    post "/bucket/protected", to: "server_bucket_spec_support/bucket_forgery#create_protected"
    get  "/bucket/csrf_token", to: "server_bucket_spec_support/bucket_forgery#csrf_token"
  end
end

RSpec.describe "Story 9.2: Ruact::Server dual-bucket response negotiation", :story_9_2 do
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  let(:json_headers) { { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" } }
  let(:flight_headers) { { "HTTP_ACCEPT" => "text/x-component" } }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
  end

  def reset_config
    Ruact.instance_variable_set(:@config, nil)
    Ruact.instance_variable_set(:@configured_at_least_once, false)
  end

  describe "Bucket 2 — normal completion serializes all exposed ivars (AC2)" do
    it "renders 200 + a JSON object keyed by ivar name, ruact_props only (no secret)" do
      post "/bucket/with_ivars", "{}", json_headers
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      body = JSON.parse(last_response.body)
      expect(body).to eq("post" => { "id" => 1, "title" => "Hi" }, "count" => 2)
      expect(body.fetch("post")).not_to have_key("secret")
    end
  end

  describe "Bucket 2 — redirect_to surfaces as $redirect (AC3)" do
    it "renders 200 + { \"$redirect\": \"<path>\" } instead of a 302 / Flight row" do
      post "/bucket/redirecting", "{}", json_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("$redirect" => "/posts/1")
    end
  end

  describe "Bucket 2 — redirect open-redirect protection (review round 1)" do
    # Turn Rails' open-redirect protection ON for this app (the bare test app
    # doesn't `load_defaults`, so it defaults to log-and-allow). `raise_on_open_redirects`
    # forces the raise path on both Rails 7.0 and 8.x.
    around do |example|
      previous = ActionController::Base.raise_on_open_redirects
      ActionController::Base.raise_on_open_redirects = true
      example.run
    ensure
      ActionController::Base.raise_on_open_redirects = previous
    end

    it "a cross-host redirect_to raises (open-redirect protection) → 500 structured, matching Rails" do
      post "/bucket/redirect_external", "{}", json_headers
      expect(last_response.status).to eq(500)
      expect(JSON.parse(last_response.body).fetch("error_class")).to match(/RedirectError/)
    end

    it "honors allow_other_host: true — emits the absolute $redirect" do
      post "/bucket/redirect_external_allowed", "{}", json_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("$redirect" => "https://allowed.example.com/x")
    end
  end

  describe "Vary preserves a host-set value (review round 1)" do
    it "appends Accept to a Vary the action set, never clobbering it" do
      post "/bucket/vary_clobber", "{}", json_headers
      vary = last_response.headers["Vary"]
      expect(vary).to match(/\bCookie\b/)
      expect(vary).to match(/\bAccept\b/)
    end
  end

  describe "Bucket 2 — empty action → 204 (AC4)" do
    it "returns 204 No Content with an empty body" do
      post "/bucket/empty", "{}", json_headers
      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
    end
  end

  describe "Bucket 2 — serialization failure routes through the 9.1 chain as 500 (AC5/AC9)" do
    before do
      # Re-prime AFTER spec_helper's global before resets @config, so strict
      # sticks for the example body (local before runs after global before).
      reset_config
      Ruact.configure { |c| c.strict_serialization = true }
    end

    it "raises Ruact::SerializationError → 500 structured payload", :aggregate_failures do
      post "/bucket/unserializable", "{}", json_headers
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("error_class")).to eq("Ruact::SerializationError")
      expect(body.fetch("message")).to match(/Cannot serialize/)
    end
  end

  describe "Vary: Accept on every non-GET shape (AC6)" do
    it "is set on the 200 ivar-JSON response" do
      post "/bucket/with_ivars", "{}", json_headers
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end

    it "is set on the 204 response" do
      post "/bucket/empty", "{}", json_headers
      expect(last_response.status).to eq(204)
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end

    it "is set on the $redirect response" do
      post "/bucket/redirecting", "{}", json_headers
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end

    it "is set on the Bucket-1 Flight response too" do
      post "/bucket/dual_redirecting", "{}", flight_headers
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end
  end

  describe "Bucket 1 — form/navigation Flight path unchanged (AC1)" do
    it "a text/x-component redirect still emits the Flight redirect row (no $redirect JSON)" do
      post "/bucket/dual_redirecting", "{}", flight_headers
      expect(last_response.headers["Content-Type"]).to include("text/x-component")
      expect(last_response.body).to eq("0:#{JSON.generate({ 'redirectUrl' => '/posts/1',
                                                            'redirectType' => 'push' })}\n")
    end
  end

  describe "CSRF on Bucket 2 — host protect_from_forgery (AC7)" do
    around do |example|
      previous = ServerBucketSpecSupport::BucketForgeryController.allow_forgery_protection
      ServerBucketSpecSupport::BucketForgeryController.allow_forgery_protection = true
      example.run
    ensure
      ServerBucketSpecSupport::BucketForgeryController.allow_forgery_protection = previous
    end

    it "valid X-CSRF-Token → 200 + serialized ivars (full round-trip)" do
      get "/bucket/csrf_token"
      token = JSON.parse(last_response.body).fetch("token")
      post "/bucket/protected", "{}", json_headers.merge("HTTP_X_CSRF_TOKEN" => token)
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("ok" => true)
    end

    it "missing X-CSRF-Token → 403 structured (via the 9.1 chain)" do
      post "/bucket/protected", "{}", json_headers
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).fetch("error_class")).to eq("ActionController::InvalidAuthenticityToken")
    end

    it "invalid X-CSRF-Token → 403 structured" do
      post "/bucket/protected", "{}", json_headers.merge("HTTP_X_CSRF_TOKEN" => "nope-not-valid")
      expect(last_response.status).to eq(403)
    end

    context "with forgery protection OFF (API mode)" do
      around do |example|
        ServerBucketSpecSupport::BucketForgeryController.allow_forgery_protection = false
        example.run
      end

      it "accepts a tokenless request and serializes ivars" do
        post "/bucket/protected", "{}", json_headers
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("ok" => true)
      end
    end
  end
end
