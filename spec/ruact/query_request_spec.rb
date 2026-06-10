# frozen_string_literal: true

# Story 9.4 — request-cycle spec for the v2 query dispatch layer, on the shared
# Story-7.9 Rails app. Pins, against REAL drawn routes (manual fetch — no
# codegen dependency; the TS `useQuery` reference is Story 9.5):
#
#   - AC1: `ruact_queries` draws one NAMED GET route per public own method at
#     `GET /q/<jsIdentifier>`; base-class and mixin methods are NOT mounted
#   - AC2: the internal dispatch controller inherits
#     `Ruact.config.query_parent_controller` — the host's REAL before_action
#     chain runs (and halts) BEFORE the query class is instantiated (FR89)
#   - AC3: the query reads `current_user` — the host's own method — end-to-end
#   - AC4: `ruact_skip_before_action` opts a query class out per-query; the
#     skipped callback provably does not run
#   - AC5: GET + no CSRF; return value serialized via ruact_props /
#     Serializable / strict_serialization; a raise → salvaged 8.4 chain (D5)
#   - AC6: `GET /q/categories` round-trips through the host chain end-to-end
#   - D6: nil return renders JSON `null` (200); D7: best-effort kwargs

require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"
require "rack/test"

require "ruact/controller"
require "ruact/server"
require "ruact/routing"

require_relative "controller_request_spec" unless defined?(ControllerRequestSpecSupport)

# The default `Ruact.config.query_parent_controller` is "ApplicationController"
# — define the conventional host parent the generated dispatch controllers
# inherit (AC2). Top-level on purpose: that is exactly what the default config
# resolves at route-draw time. Guards + CSRF mirror a real host app.
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  before_action :require_login

  private

  # Counts every run so AC4 can prove the skip means "did not run", not
  # "ran and allowed".
  def require_login
    QueryRequestSpecSupport.require_login_runs += 1
    head :unauthorized unless request.headers["X-Test-Login"] == "1"
  end

  # The host's own current_user (hand-rolled style, private) — what the
  # QueryContext delegates to via the inherited chain (AC3 / D3).
  def current_user
    return nil unless request.headers["X-Test-Login"] == "1"

    { "id" => 42, "name" => "Luiz" }
  end
end

module QueryRequestSpecSupport # rubocop:disable Style/OneClassPerFile
  class << self
    attr_accessor :require_login_runs
  end
  self.require_login_runs = 0

  # Serializable return object — :secret must never reach the wire (AC5).
  class QPost
    include Ruact::Serializable

    attr_reader :id, :title, :secret

    def initialize(id:, title:, secret:)
      @id = id
      @title = title
      @secret = secret
    end

    ruact_props :id, :title
  end

  # Non-Serializable with as_json — strict_serialization must 500 it (AC5).
  class LeakyRecord
    def as_json(_opts = nil)
      { "id" => 1, "leak" => "everything" }
    end
  end

  # AC1 fixture trio: a base-class method, a mixin method, and own methods —
  # only the own methods may be mounted.
  class ApplicationQuery < Ruact::Query
    def base_helper
      :never_mounted
    end
  end

  module QueryMixin
    def mixin_helper
      :never_mounted
    end
  end

  class CatalogQuery < ApplicationQuery
    include QueryMixin

    class << self
      attr_accessor :categories_calls
    end
    self.categories_calls = 0

    def categories
      self.class.categories_calls += 1
      [{ "value" => 1, "label" => "Books" }, { "value" => 2, "label" => "Games" }]
    end

    def whoami
      { "user" => current_user }
    end

    def echo(term: "default")
      { "term" => term }
    end

    def serialized_post
      QPost.new(id: 1, title: "Hi", secret: "s3cret")
    end

    def leaky
      LeakyRecord.new
    end

    def nothing
      nil
    end

    def boom
      raise "query exploded"
    end
  end

  # AC4 — public query class: opts out of the parent's auth callback.
  class PublicCatalogQuery < ApplicationQuery
    ruact_skip_before_action :require_login

    def open_categories
      %w[alpha beta]
    end
  end

  # Probe class for unit-level assertions (custom parent / custom prefix) so
  # rebuilding ITS controller never touches the classes the e2e routes use.
  class ProbeQuery < ApplicationQuery
    def ping
      :pong
    end
  end

  # Custom parent for the AC2 configurability unit assertion.
  class AltParentController < ActionController::Base; end

  # Story 9.5 (FR88) fixture — a required kwarg (`q`), an optional kwarg with
  # a default (`limit`), and a separate required-only method. Mounted on the
  # shared app alongside CatalogQuery so the FR88 sanitization is exercised
  # end-to-end through the host chain.
  class SearchQuery < ApplicationQuery
    # `q` is the natural query parameter name and is asserted verbatim in the
    # FR88 rejection messages below.
    def search(q:, limit: "10") # rubocop:disable Naming/MethodParameterName
      { "q" => q, "limit" => limit }
    end

    def tags(filter:)
      { "filter" => filter }
    end
  end
end

if defined?(ControllerRequestSpecSupport) &&
   !ControllerRequestSpecSupport.instance_variable_get(:@__ruact_query_routes_appended)
  ControllerRequestSpecSupport.instance_variable_set(:@__ruact_query_routes_appended, true)
  ControllerRequestSpecSupport.app_class.routes.append do
    ruact_queries QueryRequestSpecSupport::CatalogQuery,
                  QueryRequestSpecSupport::PublicCatalogQuery,
                  QueryRequestSpecSupport::SearchQuery
  end
end

RSpec.describe "Story 9.4: Ruact::Query + ruact_queries dispatch", :story_9_4 do # rubocop:disable RSpec/MultipleDescribes
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  let(:login_headers) { { "HTTP_X_TEST_LOGIN" => "1" } }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
  end

  def reset_config
    Ruact.instance_variable_set(:@config, nil)
    Ruact.instance_variable_set(:@configured_at_least_once, false)
  end

  describe "AC1 — ruact_queries draws one named GET route per public own method" do
    let(:drawn) { app_class.routes.routes }
    let(:named) { drawn.filter_map(&:name) }

    it "mounts every public_instance_methods(false) of the subclass at /q/<jsIdentifier>" do
      expect(named).to include(
        "ruact_query_categories", "ruact_query_whoami", "ruact_query_echo",
        "ruact_query_serializedPost", "ruact_query_leaky", "ruact_query_nothing",
        "ruact_query_boom", "ruact_query_openCategories"
      )
    end

    it "does NOT mount base-class methods, mixin methods, or the Ruact::Query accessors" do
      expect(named).not_to include(
        "ruact_query_baseHelper", "ruact_query_mixinHelper",
        "ruact_query_currentUser", "ruact_query_params",
        "ruact_query_request", "ruact_query_session"
      )
    end

    it "draws GET routes under the default /q prefix, snake_case → camelCase (D4)" do
      route = drawn.find { |r| r.name == "ruact_query_serializedPost" }
      expect(route.verb).to eq("GET")
      expect(route.path.spec.to_s).to eq("/q/serializedPost(.:format)")
    end

    it "honors a custom Ruact.config.query_route_prefix on a fresh draw (contract decision #7)" do
      reset_config
      Ruact.configure { |c| c.query_route_prefix = "/api/queries" }
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { ruact_queries QueryRequestSpecSupport::ProbeQuery }
      expect(route_set.routes.map { |r| r.path.spec.to_s }).to include("/api/queries/ping(.:format)")
    end
  end

  describe "AC2 — dispatch controller inherits the host parent; chain runs BEFORE instantiation (FR89)" do
    it "inherits Ruact.config.query_parent_controller (default ApplicationController)" do
      controller = Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::CatalogQuery)
      expect(controller.superclass).to be(ApplicationController)
    end

    it "honors a custom query_parent_controller" do
      reset_config
      Ruact.configure { |c| c.query_parent_controller = "QueryRequestSpecSupport::AltParentController" }
      controller = Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery)
      expect(controller.superclass).to be(QueryRequestSpecSupport::AltParentController)
    end

    it "raises Ruact::ConfigurationError at route-draw when the parent name does not resolve" do
      reset_config
      Ruact.configure { |c| c.query_parent_controller = "NoSuchParentController" }
      expect { Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery) }
        .to raise_error(Ruact::ConfigurationError, /NoSuchParentController.*does not resolve/m)
    end

    it "a halting before_action rejects the request and the query class is never instantiated" do
      calls_before = QueryRequestSpecSupport::CatalogQuery.categories_calls
      get "/q/categories"
      expect(last_response.status).to eq(401)
      expect(QueryRequestSpecSupport::CatalogQuery.categories_calls).to eq(calls_before)
    end
  end

  describe "AC6 — GET /q/categories end-to-end through the host chain (manual fetch)" do
    it "round-trips: 200, JSON content type, serialized return value" do
      get "/q/categories", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(JSON.parse(last_response.body)).to eq(
        [{ "value" => 1, "label" => "Books" }, { "value" => 2, "label" => "Games" }]
      )
    end
  end

  describe "AC3 — current_user delegates to the host's own (private) method" do
    it "the query reads the authenticated user end-to-end" do
      get "/q/whoami", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("user" => { "id" => 42, "name" => "Luiz" })
    end
  end

  describe "AC4 — per-query callback opt-out (ruact_skip_before_action)" do
    it "without the opt-out, the unauthenticated request is rejected (control)" do
      get "/q/categories"
      expect(last_response.status).to eq(401)
    end

    it "with the opt-out, the skipped callback does NOT run and the query returns" do
      runs_before = QueryRequestSpecSupport.require_login_runs
      get "/q/openCategories"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq(%w[alpha beta])
      expect(QueryRequestSpecSupport.require_login_runs).to eq(runs_before)
    end

    it "the opt-out does not leak to sibling query classes" do
      get "/q/whoami"
      expect(last_response.status).to eq(401)
    end
  end

  describe "AC5 — GET, no CSRF, serialized return value, error chain" do
    it "a tokenless GET succeeds despite protect_from_forgery with: :exception (queries are reads)" do
      get "/q/categories", {}, login_headers
      expect(last_response.status).to eq(200)
    end

    it "serializes a Serializable return through ruact_props — :secret never leaks" do
      get "/q/serializedPost", {}, login_headers
      body = JSON.parse(last_response.body)
      expect(body).to eq("id" => 1, "title" => "Hi")
      expect(body).not_to have_key("secret")
    end

    it "under strict_serialization, a non-Serializable return → structured 500 (SerializationError)" do
      reset_config
      Ruact.configure { |c| c.strict_serialization = true }
      get "/q/leaky", {}, login_headers
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("error_class")).to eq("Ruact::SerializationError")
      expect(body.fetch("message")).to match(/Cannot serialize QueryRequestSpecSupport::LeakyRecord/)
    end

    it "a query raise renders the salvaged 8.4 structured payload on a GET (D5 gate override)" do
      get "/q/boom", {}, login_headers
      expect(last_response.status).to eq(500)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("action_name")).to eq("boom")
      expect(body.fetch("error_class")).to eq("RuntimeError")
      expect(body.fetch("message")).to eq("query exploded")
    end
  end

  describe "D6 — nil return renders JSON null (200), not 204" do
    it "renders the literal null body" do
      get "/q/nothing", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("null")
    end
  end

  describe "D7 — best-effort kwargs from GET query params (strict FR88 sanitization is 9.5)" do
    it "passes a declared keyword argument by name" do
      get "/q/echo?term=ruby", {}, login_headers
      expect(JSON.parse(last_response.body)).to eq("term" => "ruby")
    end

    it "omits an absent keyword so the method default applies" do
      get "/q/echo", {}, login_headers
      expect(JSON.parse(last_response.body)).to eq("term" => "default")
    end
  end

  describe "review round 1 — query method names colliding with controller plumbing are rejected" do
    it "raises Ruact::ConfigurationError when a query method would shadow a framework method" do
      shadowing = Class.new(Ruact::Query) do
        def params
          :shadowed
        end
      end
      stub_const("QueryRequestSpecSupport::ParamsShadowQuery", shadowing)
      expect { Ruact::ServerFunctions::QueryDispatch.controller_for(shadowing) }
        .to raise_error(Ruact::ConfigurationError, /\bparams\b.*already defined/m)
    end

    it "rejects `render` too (any name on the generated controller chain)" do
      shadowing = Class.new(Ruact::Query) do
        def render
          :shadowed
        end
      end
      stub_const("QueryRequestSpecSupport::RenderShadowQuery", shadowing)
      expect { Ruact::ServerFunctions::QueryDispatch.controller_for(shadowing) }
        .to raise_error(Ruact::ConfigurationError, /\brender\b.*already defined/m)
    end
  end

  describe "review round 4 — namespace is PRESERVED so collisions are impossible by construction" do
    it "maps Admin::CatalogQuery and AdminCatalogQuery to DISTINCT controllers + route targets" do
      namespaced = Class.new(Ruact::Query) { def ping_a = :a }
      flat       = Class.new(Ruact::Query) { def ping_b = :b }
      stub_const("QueryRequestSpecSupport::Nspace::CatalogQuery", namespaced)
      stub_const("QueryRequestSpecSupport::NspaceCatalogQuery", flat)

      c1 = Ruact::ServerFunctions::QueryDispatch.controller_for(namespaced)
      c2 = Ruact::ServerFunctions::QueryDispatch.controller_for(flat)

      # Every namespace segment is preserved (`::Nspace::CatalogQuery` keeps the
      # boundary; `NspaceCatalogQuery` has no boundary) — the two map to
      # DISTINCT nested constants, so a const overwrite / cross-wire is
      # impossible regardless of how many RouteSets share the dispatch module.
      expect(c1).not_to be(c2)
      expect(c1.name).to eq(
        "Ruact::ServerFunctions::QueryDispatch::QueryRequestSpecSupport::Nspace::CatalogQueryController"
      )
      expect(c2.name).to eq(
        "Ruact::ServerFunctions::QueryDispatch::QueryRequestSpecSupport::NspaceCatalogQueryController"
      )
      expect(Ruact::ServerFunctions::QueryDispatch.route_target_for(namespaced))
        .to eq("ruact/server_functions/query_dispatch/query_request_spec_support/nspace/catalog_query")
      expect(Ruact::ServerFunctions::QueryDispatch.route_target_for(flat))
        .to eq("ruact/server_functions/query_dispatch/query_request_spec_support/nspace_catalog_query")
    end

    it "mounts both on the same RouteSet without error, each routing to its own class (no cross-wiring)" do
      namespaced = Class.new(Ruact::Query) { def from_ns = "ns" }
      flat       = Class.new(Ruact::Query) { def from_flat = "flat" }
      stub_const("QueryRequestSpecSupport::Pair::TwinQuery", namespaced)
      stub_const("QueryRequestSpecSupport::PairTwinQuery", flat)

      route_set = ActionDispatch::Routing::RouteSet.new
      expect do
        route_set.draw do
          ruact_queries namespaced
          ruact_queries flat
        end
      end.not_to raise_error

      targets = route_set.routes.filter_map { |r| r.defaults[:controller] }
      expect(targets).to include(
        "ruact/server_functions/query_dispatch/query_request_spec_support/pair/twin_query",
        "ruact/server_functions/query_dispatch/query_request_spec_support/pair_twin_query"
      )
    end

    it "round-trips acronym namespaces so Rails resolves the generated controller (round 5)" do
      acro = Class.new(Ruact::Query) { def ping_e = :e }
      stub_const("QueryRequestSpecSupport::APIProbe::CatalogQuery", acro)

      controller = Ruact::ServerFunctions::QueryDispatch.controller_for(acro)
      target = Ruact::ServerFunctions::QueryDispatch.route_target_for(acro)
      # Exactly how Rails' dispatcher resolves a "controller#action" target.
      resolved = "#{target.camelize}Controller".constantize

      expect(resolved).to be(controller)
      expect(target).to eq(
        "ruact/server_functions/query_dispatch/query_request_spec_support/api_probe/catalog_query"
      )
    end

    it "the SAME class re-mounting (dev reload) is still allowed" do
      expect do
        Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery)
        Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery)
      end.not_to raise_error
    end
  end

  describe "regeneration is idempotent (dev-mode routes reload)" do
    it "controller_for builds a fresh class on every call without const warnings" do
      first  = Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery)
      second = Ruact::ServerFunctions::QueryDispatch.controller_for(QueryRequestSpecSupport::ProbeQuery)
      expect(second).not_to be(first)
      expect(second.superclass).to be(ApplicationController)
    end
  end
end

RSpec.describe "Story 9.5: FR88 query kwargs sanitization", :story_9_5 do
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  let(:login_headers) { { "HTTP_X_TEST_LOGIN" => "1" } }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
  end

  def structured_error(response)
    expect(response.status).to eq(400)
    body = JSON.parse(response.body)
    expect(body.fetch("_ruact_server_action_error")).to be(true)
    expect(body.fetch("error_class")).to eq("Ruact::BadRequestError")
    body
  end

  describe "AC3 happy path — declared primitives pass" do
    it "passes a required + optional kwarg by name (values arrive as strings)" do
      get "/q/search?q=ruby&limit=5", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("q" => "ruby", "limit" => "5")
    end

    it "omits an absent optional kwarg so the method default applies" do
      get "/q/search?q=ruby", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("q" => "ruby", "limit" => "10")
    end

    it "accepts boolean-ish / numeric-ish primitive strings on the wire" do
      get "/q/search?q=true&limit=0", {}, login_headers
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("q" => "true", "limit" => "0")
    end
  end

  describe "AC3 — array param rejected (only string/number/boolean/null allowed)" do
    it "400s with a descriptive error naming the key and the allowlist" do
      get "/q/search?q[]=a&q[]=b", {}, login_headers
      body = structured_error(last_response)
      expect(body.fetch("message")).to match(/:q must be a string, number, boolean, or null/)
      expect(body.fetch("message")).to match(/arrays and objects are rejected/)
    end
  end

  describe "AC3 — object (hash) param rejected" do
    it "400s with a descriptive error naming the offending key" do
      get "/q/search?q[deep]=1", {}, login_headers
      body = structured_error(last_response)
      expect(body.fetch("message")).to match(/:q must be a string, number, boolean, or null/)
    end
  end

  describe "AC3 — missing required kwarg → 400 naming the missing parameter" do
    it "400s naming :q when it is absent" do
      get "/q/search?limit=5", {}, login_headers
      body = structured_error(last_response)
      expect(body.fetch("message")).to match(/missing required parameter\(s\) :q/)
      expect(body.fetch("action_name")).to eq("search")
    end

    it "400s naming :filter on a required-only method" do
      get "/q/tags", {}, login_headers
      body = structured_error(last_response)
      expect(body.fetch("message")).to match(/missing required parameter\(s\) :filter/)
    end
  end

  describe "AC3 — unknown param → 400 (rejected, not silently dropped)" do
    it "400s naming the unknown parameter" do
      get "/q/search?q=ruby&bogus=1", {}, login_headers
      body = structured_error(last_response)
      expect(body.fetch("message")).to match(/unknown parameter :bogus/)
    end

    it "rejects before running the query even when the declared param is also present" do
      get "/q/search?q=ruby&bogus=1", {}, login_headers
      expect(last_response.status).to eq(400)
    end
  end
end
