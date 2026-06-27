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
require "active_model"

require_relative "controller_request_spec" unless defined?(ControllerRequestSpecSupport)

module ServerBucketSpecSupport
  # Story 13.3 (FR98) — an ActiveModel record with a presence validation, so a
  # host action can exercise the non-exception `if record.valid? … else …`
  # happy-failure path that `ruact_errors` round-trips.
  class ValidatedPost
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :title, :string

    validates :title, presence: true

    def self.name = "ValidatedPost"
  end

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

    # Review round 2 — a host that sets Vary: * (uncacheable wildcard) must keep
    # it as-is, not "*, Accept".
    def vary_wildcard
      response.headers["Vary"] = "*"
      @ok = true
    end

    def unserializable
      @rec = UnserializableRecord.new
    end

    # Story 13.3 (FR98) — opted-in FAILED validation: `ruact_errors(post)` after
    # an invalid save attempt registers the canonical errors; Bucket-2 injects
    # them under the reserved `errors` key alongside the serialized ivars.
    def validated_create_invalid
      post = ServerBucketSpecSupport::ValidatedPost.new(title: nil)
      @created = post.valid? # false → populates post.errors
      ruact_errors(post)
    end

    # Story 13.3 (FR98) — opted-in SUCCESS: the SAME call path yields
    # `errors: {}` (success symmetry), so the client reads `result.errors`
    # uniformly on both branches.
    def validated_create_valid
      post = ServerBucketSpecSupport::ValidatedPost.new(title: "Hi")
      @created = post.valid? # true → post.errors empty
      ruact_errors(post)
    end

    # Story 13.3 (FR98) — a stray dev ivar literally named `@errors` must NOT
    # clobber the reserved round-trip key: the collector is the source of truth.
    def stray_errors_ivar
      @errors = "a dev string that must not win"
      post = ServerBucketSpecSupport::ValidatedPost.new(title: nil)
      post.valid?
      ruact_errors(post)
    end
  end

  # Review round 2 — an auth-style before_action that redirects on a Bucket-2
  # call: the response is performed in the before_action, so after-callbacks are
  # skipped — Vary must still be present (set by a before_action too).
  class BucketBeforeRedirectController < ActionController::Base
    include Ruact::Server

    before_action :bounce

    def never_runs
      @ok = true
    end

    private

    def bounce
      redirect_to "/login"
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

  # Story 10.0 (AC5) — the scaffold's resource-controller shape: includes BOTH
  # Ruact::Controller and Ruact::Server (ApplicationController contributes
  # Controller; the resource controller adds Server). An ivar-only GET page
  # action (implicit `default_render`) backed by a conventional template must
  # flow Server#default_render → super (GET is never a function call) → the
  # now-fixed Controller#default_render → HTML shell, NOT a 500.
  class ServerImplicitController < ActionController::Base
    include Ruact::Controller
    include Ruact::Server

    def show; end
  end
end

# Story 10.0 (AC5) — conventional template under the shared app root so the
# Server-including controller's implicit GET reaches Controller#default_render.
ControllerRequestSpecSupport.write_view(
  "server_bucket_spec_support/server_implicit", "show", <<~ERB
    <div>
      <DemoButton label={"hi"} />
    </div>
  ERB
)

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
    post "/bucket/vary_wildcard",   to: "server_bucket_spec_support/bucket_server#vary_wildcard"
    post "/bucket/before_redirect", to: "server_bucket_spec_support/bucket_before_redirect#never_runs"
    post "/bucket/unserializable",  to: "server_bucket_spec_support/bucket_server#unserializable"
    post "/bucket/validated_create_invalid", to: "server_bucket_spec_support/bucket_server#validated_create_invalid"
    post "/bucket/validated_create_valid",   to: "server_bucket_spec_support/bucket_server#validated_create_valid"
    post "/bucket/stray_errors_ivar", to: "server_bucket_spec_support/bucket_server#stray_errors_ivar"
    post "/bucket/dual_redirecting", to: "server_bucket_spec_support/bucket_dual#redirecting"
    post "/bucket/protected", to: "server_bucket_spec_support/bucket_forgery#create_protected"
    get  "/bucket/csrf_token", to: "server_bucket_spec_support/bucket_forgery#csrf_token"
    # Story 10.0 (AC5) — Server-including controller's implicit GET page action.
    get  "/server-implicit/show", to: "server_bucket_spec_support/server_implicit#show"
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
    # Story 10.0 (AC5) — pin Rails.root so the Server-path implicit-render
    # template (`Rails.root/app/views`) is found regardless of full-suite
    # ordering leftovers (see controller_request_spec.rb for the rationale).
    Rails.root = ControllerRequestSpecSupport.app_root
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

  describe "Vary edge cases (review round 2)" do
    it "is set on a $redirect performed by a before_action (after-callbacks skipped)" do
      post "/bucket/before_redirect", "{}", json_headers
      expect(JSON.parse(last_response.body)).to eq("$redirect" => "/login")
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end

    it "preserves a host Vary: * wildcard as-is (does not produce '*, Accept')" do
      post "/bucket/vary_wildcard", "{}", json_headers
      expect(last_response.headers["Vary"]).to eq("*")
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

  # Story 13.3 (FR98) — the Bucket-2 (imperative `await`) half of the
  # Inertia-style validation `errors` round-trip (AC3).
  describe "Story 13.3: Bucket-2 errors round-trip (FR98)", :story_13_3 do
    it "FAILED validation injects the canonical errors under the reserved `errors` key" do
      post "/bucket/validated_create_invalid", "{}", json_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to eq("created" => false, "errors" => { "title" => ["Title can't be blank"] })
    end

    it "SUCCESS yields `errors: {}` through the same call path (success symmetry)" do
      post "/bucket/validated_create_valid", "{}", json_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to eq("created" => true, "errors" => {})
    end

    it "is set with Vary: Accept like every other non-GET shape" do
      post "/bucket/validated_create_valid", "{}", json_headers
      expect(last_response.headers["Vary"]).to match(/\bAccept\b/)
    end

    it "the collector wins over a stray dev ivar literally named @errors" do
      post "/bucket/stray_errors_ivar", "{}", json_headers
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("errors")).to eq("title" => ["Title can't be blank"])
    end

    it "preserves the 9.2 untouched-collector contract: an empty opted-out action still 204s" do
      # `empty_action` never calls `ruact_errors` → no `errors` key, 204 No Content.
      post "/bucket/empty", "{}", json_headers
      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
    end

    it "preserves the 9.2 untouched-collector contract: a populated action carries NO errors key" do
      # `with_ivars` sets ivars but never opts in → body has no `errors` key.
      post "/bucket/with_ivars", "{}", json_headers
      expect(JSON.parse(last_response.body)).not_to have_key("errors")
    end

    # AC5(e) coexistence: the RAISED `ActiveRecord::RecordInvalid` path still
    # renders the structured 422 error payload — proven (unchanged) by
    # server_rescue_request_spec.rb's `record_invalid` example. 13.3 is the
    # NON-raised 200 path above; the two contracts stay distinct.
  end

  # Story 10.0 (AC5) — the Server-path inherits the default_render graceful
  # degradation fix. A GET is never a function call, so Server#default_render
  # delegates to super → the fixed Controller#default_render.
  describe "Story 10.0: Server path inherits non-HTML Accept graceful degradation (AC5)", :story_10_0 do
    it "GET with Accept: */* returns the HTML shell, not a 500" do
      get "/server-implicit/show", {}, { "HTTP_ACCEPT" => "*/*" }
      expect(last_response.status).to(eq(200),
                                      "expected 200, got #{last_response.status} body=#{last_response.body[0, 400]}")
      expect(last_response.headers["Content-Type"]).to include("text/html")
      expect(last_response.body).to include("DemoButton")
      expect(last_response.body).not_to include("__ruact_component__ called outside a ruact_render flow")
    end

    it "GET with Accept: text/x-component returns a Flight payload (function-call path untouched)" do
      get "/server-implicit/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("text/x-component")
    end
  end
end
