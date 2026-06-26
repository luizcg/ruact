# frozen_string_literal: true

# Story 7.9 — Bug 7.8-B regression spec.
#
# Exercises Ruact::Controller end-to-end through Rails 8's full controller
# lifecycle (ActionController::Base#dispatch → ActionView::Base allocation →
# template render → __ruact_component__ helper). The bug closed by this spec
# was invisible to unit-only controller_spec.rb because that file stubs
# render_to_string and never instantiates ActionView::Base.
#
# Rails request-cycle subsystems are loaded HERE (not in spec_helper.rb) so
# the rest of the suite continues to use spec/support/rails_stub.rb without
# paying the action_controller / action_view boot cost.
require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"

require "rack/test"
require "tmpdir"
require "fileutils"
require "active_model"

# Ruact::Controller is normally loaded by the Railtie's `ruact.load_controller`
# initializer at app boot. This spec instantiates a Rails::Application but does
# not depend on initializer ordering, so we load the concern explicitly.
require "ruact/controller"

# Test-support helpers and demo controller — top-level so the Rails routes
# resolver finds them. Defined before the describe block so the controller
# class exists when routes are appended.
module ControllerRequestSpecSupport
  class << self
    attr_reader :manifest_path

    def app_class
      @app_class ||= build_app_class
    end

    def boot!
      return if @booted

      @tmpdir        = Dir.mktmpdir("ruact-story-7-9")
      @manifest_path = File.join(@tmpdir, "react-client-manifest.json")
      File.write(@manifest_path, JSON.dump(
                                   "DemoButton" => {
                                     "id" => "/DemoButton.jsx",
                                     "name" => "DemoButton",
                                     "chunks" => ["/DemoButton.jsx"]
                                   }
                                 ))

      # Story 7.3: Ruact.config is frozen after the first configure block. The
      # spec_helper before hook resets it between examples; the describe's
      # per-example `before` re-primes the manifest_path. Here we just put the
      # initial state in place and cache the manifest at module level so it
      # survives subsequent config resets.
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure do |c|
        c.manifest_path = @manifest_path
      end
      Ruact.manifest # prime the cache

      app_class.instance.initialize!
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

        routes.append do
          get "/demo/show", to: "controller_request_spec_support/demo#show"
          # Story 13.3 (FR98) — Bucket-1 redirect-back round-trip routes.
          get  "/errors-demo/new",          to: "controller_request_spec_support/errors_demo#new"
          post "/errors-demo/create",       to: "controller_request_spec_support/errors_demo#create"
          post "/errors-demo/create_valid", to: "controller_request_spec_support/errors_demo#create_valid"
        end
      end
    end
  end

  # Story 13.3 (FR98) — an ActiveModel record with a presence validation for the
  # redirect-back round-trip demo controller below.
  class ErrorsDemoPost
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :title, :string

    validates :title, presence: true

    def self.name = "ErrorsDemoPost"
  end

  # Story 13.3 (FR98) — the Bucket-1 (native form / navigation) Inertia-style
  # redirect-back demo: `create` registers errors via `ruact_errors` then
  # `redirect_to`s the form; the errors survive the Flight redirect in `flash`
  # and arrive as an `errors` prop on the re-rendered `new` page.
  class ErrorsDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def new
      ruact_render
    end

    def create
      post = ErrorsDemoPost.new(title: nil)
      post.valid? # false → populates errors
      ruact_errors(post)
      redirect_to "/errors-demo/new"
    end

    def create_valid
      post = ErrorsDemoPost.new(title: "Hi")
      post.valid? # true → no errors
      ruact_errors(post)
      redirect_to "/errors-demo/new"
    end
  end

  # Demo controller for the spec. Uses an inline `append_view_path` instead of
  # relying on Rails.root/app/views, so Controller#ruact_render is invoked
  # directly from #show rather than via default_render (which short-circuits
  # when the conventional template path does not exist on disk).
  class DemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def show
      ruact_render
    end
  end
end

# Reset Rails.application so this spec can boot its own minimal app even if a
# prior spec ran a different Rails::Application subclass (the constant is
# memoized in Rails::Application; we own the reset here).
Rails.application = nil if Rails.respond_to?(:application) && !Rails.application.is_a?(Rails::Application)

module Ruact # rubocop:disable Style/OneClassPerFile
  RSpec.describe "Story 7.9: Bug 7.8-B — render_to_string view-context ivar handoff", :story_7_9 do
    include Rack::Test::Methods

    let(:app_class) { ControllerRequestSpecSupport.app_class }
    let(:app)       { app_class.instance }

    # Boot lives inside a per-example `before` hook (not `before(:all)`) so
    # RSpec's per-test lifecycle for rspec-mocks is active when Rails
    # initializers fire. Boot is memoized so the cost is paid once across all
    # examples.
    before do
      # railtie_spec.rb assigns Rails.logger to an instance_double via the
      # writer (not via rspec-mocks); the assignment persists across examples
      # and the request-cycle code path calls Rails.logger.* — replace with a
      # real logger that survives the example lifecycle.
      Rails.logger = Logger.new(IO::NULL)
      ControllerRequestSpecSupport.boot!
      # Re-prime Ruact.config after spec_helper's per-example reset wiped it.
      Ruact.configure do |c|
        c.manifest_path = ControllerRequestSpecSupport.manifest_path
      end
    end

    describe "happy path: PascalCase tag renders successfully" do
      it "GET /demo/show returns 200 with the Flight payload (was 500 pre-7.9)" do
        get "/demo/show"
        expect(last_response.status).to(eq(200),
                                        "expected 200, got #{last_response.status} body=#{last_response.body[0, 400]}")
        expect(last_response.body).to include("DemoButton")
      end

      it "RSC request returns text/x-component with the registered component" do
        get "/demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/x-component")
        expect(last_response.body).to include("DemoButton")
      end
    end

    describe "regression guard: render context reaches ViewHelper" do
      it "ViewHelper#__ruact_component__ does NOT raise the outside-flow error" do
        # If the handoff regresses, the request returns 500 with this exact
        # message in the body or raises the exception in the request chain.
        get "/demo/show"
        expect(last_response.body).not_to include("__ruact_component__ called outside a ruact_render flow")
      end

      it "Flight payload contains the registered component import row" do
        # End-to-end probe: a successful render emits a Flight I-row (import)
        # for every registered client component. The presence of the
        # DemoButton's module path proves the handoff ran end-to-end rather
        # than the request happening to 200 for some unrelated reason.
        get "/demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200)
        expect(last_response.body).to match(%r{\h+:I\[.*/DemoButton\.jsx}),
                                      "expected a Flight I-row referencing /DemoButton.jsx; " \
                                      "got: #{last_response.body[0, 400]}"
      end

      it "render context is cleared after the render returns" do
        # AC-adjacent regression: the controller's ensure block must restore
        # @ruact_render_context so a subsequent error/rescue render in the
        # same request cannot see stale context. Re-issuing the same request
        # on the same Rack stack exercises the per-request lifecycle.
        get "/demo/show"
        get "/demo/show"
        expect(last_response.status).to eq(200)
      end

      it "ensure block removes the ivar entirely when it was not defined before" do
        # Direct unit-level guard: when ruact_render starts on a controller
        # instance with no prior @ruact_render_context, the ensure block
        # must put the controller back into the instance_variable_defined?
        # = false state — not into the "ivar is defined as nil" state,
        # which would leak a phantom `{"ruact_render_context" => nil}`
        # entry into view_assigns on any subsequent error render.
        controller = ControllerRequestSpecSupport::DemoController.new
        controller.instance_variable_set(:@_request, nil)
        # Invoke just the ivar lifecycle by stubbing the heavy parts.
        allow(controller).to receive_messages(
          render_to_string: "<div></div>",
          ruact_request?: false,
          ruact_manifest: Ruact.manifest,
          controller_path: "controller_request_spec_support/demo",
          logger: Logger.new(IO::NULL),
          action_name: "show"
        )
        allow(controller).to receive(:render)

        expect(controller.instance_variable_defined?(:@ruact_render_context)).to be(false)
        controller.send(:ruact_render)
        expect(controller.instance_variable_defined?(:@ruact_render_context)).to be(false)
      end
    end

    # Story 13.3 (FR98) — the Bucket-1 (native form / navigation) half of the
    # Inertia-style validation `errors` round-trip (AC4): errors survive a
    # redirect-back in flash and arrive as an `errors` prop on the re-render.
    describe "Story 13.3: redirect-back errors prop (FR98)", :story_13_3 do
      let(:flight_headers) { { "HTTP_ACCEPT" => "text/x-component" } }

      it "exposes errors={} on a plain page render with no prior redirect (always present)" do
        get "/errors-demo/new", {}, flight_headers
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("DemoButton")
        # The component receives a present-but-empty errors prop, never a message.
        expect(last_response.body).not_to include("can't be blank")
      end

      it "survives a redirect-back and re-renders with the errors prop populated" do
        # Writing request (Bucket 1, Flight): registers errors, then redirects.
        post "/errors-demo/create", {}, flight_headers
        expect(last_response.headers["Content-Type"]).to include("text/x-component")
        expect(last_response.body).to include("redirectUrl")

        # The router follows the redirect with a fresh Flight GET; rack-test
        # carries the session cookie, so flash[:ruact_errors] is read back.
        get "/errors-demo/new", {}, flight_headers
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Title can't be blank")
      end

      it "registers errors={} for a successful save and does NOT leak a message across the redirect" do
        post "/errors-demo/create_valid", {}, flight_headers
        get "/errors-demo/new", {}, flight_headers
        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("can't be blank")
      end

      it "is single-use: a second re-render after the flash is swept shows no errors" do
        post "/errors-demo/create", {}, flight_headers
        get "/errors-demo/new", {}, flight_headers
        expect(last_response.body).to include("Title can't be blank")

        # flash is swept after the first read; the next render is clean.
        get "/errors-demo/new", {}, flight_headers
        expect(last_response.body).not_to include("Title can't be blank")
      end
    end
  end
end
