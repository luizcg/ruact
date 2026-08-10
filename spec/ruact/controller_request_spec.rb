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
require "pathname"
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

    # Story 10.0 — a writable on-disk app root so an implicit-`default_render`
    # controller's conventional template (`Rails.root/app/views/<ctrl>/<action>`)
    # exists. Unlike the `append_view_path` demo controllers (which call
    # `ruact_render` directly), the implicit path is what `ruact_template_exists?`
    # probes — the bug under test lives in `default_render`, never reached when a
    # template is only on an appended path. Memoized so `config.root` and every
    # `write_view` call share one directory.
    def app_root
      @app_root ||= Pathname.new(Dir.mktmpdir("ruact-story-10-0-root"))
    end

    # Story 10.0 — write a conventional template under the app root so Rails'
    # default view path picks it up and `ruact_template_exists?` returns true.
    # Called at file-load time (before `initialize!`) so the `app/views` dir
    # exists when Rails computes `paths["app/views"].existent`.
    def write_view(controller_path, action, erb)
      view_dir = File.join(app_root, "app", "views", controller_path)
      FileUtils.mkdir_p(view_dir)
      File.write(File.join(view_dir, "#{action}.html.erb"), erb)
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
      app_root_path = app_root
      Class.new(Rails::Application) do
        # Story 10.0 — a real on-disk root so the implicit-render controller's
        # conventional `app/views` template is discoverable by `default_render`.
        config.root                              = app_root_path
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
          # Story 10.0 — implicit-`default_render` page action (empty body), backed
          # by a conventional `Rails.root/app/views` template, for the non-HTML
          # Accept graceful-degradation matrix.
          get "/implicit-demo/show", to: "controller_request_spec_support/implicit_demo#show"
          # Story 13.3 (FR98) — Bucket-1 redirect-back round-trip routes.
          get  "/errors-demo/new",          to: "controller_request_spec_support/errors_demo#new"
          post "/errors-demo/create",       to: "controller_request_spec_support/errors_demo#create"
          post "/errors-demo/create_valid", to: "controller_request_spec_support/errors_demo#create_valid"
          # The layout owns the document — a page rendered through a migrated
          # host layout, and one through a layout that never calls
          # `ruact_js_assets`.
          get "/layout-demo/show",         to: "controller_request_spec_support/layout_demo#show"
          get "/unwired-layout-demo/show", to: "controller_request_spec_support/unwired_layout_demo#show"
          get "/exploding-layout-demo/show", to: "controller_request_spec_support/exploding_layout_demo#show"
          get "/rootless-layout-demo/show", to: "controller_request_spec_support/rootless_layout_demo#show"
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

  # Story 10.0 — an implicit-`default_render` page controller: an EMPTY GET
  # action (no `render`/`respond_to`), backed by a CONVENTIONAL template at
  # `Rails.root/app/views/.../show.html.erb` (written via `write_view` below).
  # This is the exact scaffold shape (ivar-only GET) whose `*/*` request 500'd
  # pre-10.0. No `append_view_path` — the template must live on the default path
  # that `ruact_template_exists?` probes for the bug to be reachable.
  class ImplicitDemoController < ActionController::Base
    include Ruact::Controller

    def show; end
  end

  # The layout owns the document. Both controllers declare a NAMED layout
  # instead of relying on `layouts/application`, so adding them cannot change
  # what every other controller in this file renders (the rest have no
  # resolvable layout and must keep getting ruact's built-in shell).
  class LayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "ruact_host"

    def show
      ruact_render
    end
  end

  # An unmigrated layout that RAISES if rendered (it reads an ivar a ruact
  # action never sets). Under `:auto` ruact must never execute it.
  class ExplodingLayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "exploding_host"

    def show
      ruact_render
    end
  end

  # A layout that calls `ruact_js_assets` but has no root div to mount into.
  class RootlessLayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "rootless_host"

    def show
      ruact_render
    end
  end

  # Same page, but through a layout that never calls `ruact_js_assets` — the
  # state every app installed before the layout owned the document is in.
  class UnwiredLayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "bare_host"

    def show
      ruact_render
    end
  end
end

# Story 10.0 — write the implicit-render template at file-load time (before the
# app's `initialize!` in `boot!`) so the `app/views` dir exists when Rails
# computes its view paths.
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/implicit_demo", "show", <<~ERB
    <div>
      <DemoButton label={"hello"} />
    </div>
  ERB
)

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
      # Story 10.0 — pin Rails.root to the booted app root. The Rails.root stub
      # (spec/support/rails_stub.rb) is a writable singleton ivar; doctor_spec
      # sets `Rails.root = <its tmpdir>` and never clears it, so in full-suite
      # ordering a leftover root would make `ruact_template_exists?` (which
      # probes `Rails.root/app/views`) miss the implicit-render template → super
      # → the very 500 this story closes. Re-pinning per example is order-proof.
      Rails.root = ControllerRequestSpecSupport.app_root
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

    # The bug this closes: a ruact page could not carry ANY of the host app's
    # CSS. `ruact_render` rendered the view with `layout: false` and then wrapped
    # the payload in a hardcoded shell whose `<head>` has no stylesheet slot, so
    # `stylesheet_link_tag` in the app's layout never reached the browser. The
    # generated `--shadcn` scaffold was therefore unstyled by construction, and
    # Epic 12 (`ruact_meta` → tags in `<head>`) had no surface to write into.
    describe "the layout owns the document" do
      it "puts the host app's stylesheet on a ruact page (the CSS could not arrive before)" do
        get "/layout-demo/show"

        expect(last_response.status).to(eq(200),
                                        "expected 200, got #{last_response.status} " \
                                        "body=#{last_response.body[0, 400]}")
        expect(last_response.body).to include('<link rel="stylesheet" href="/host-app.css" />')
      end

      it "keeps the host layout's own <title> instead of ruact's placeholder" do
        get "/layout-demo/show"

        expect(last_response.body).to include("<title>Host App Title</title>")
        expect(last_response.body).not_to include("Rails RSC")
      end

      it "still ships the Flight payload and the component, through the layout's ruact_js_assets" do
        get "/layout-demo/show"

        expect(last_response.body).to include("__FLIGHT_DATA")
        expect(last_response.body).to include("DemoButton")
      end

      it "does not apply the layout to a Flight request (the wire shape is unchanged)" do
        get "/layout-demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }

        expect(last_response.headers["Content-Type"]).to include("text/x-component")
        expect(last_response.body).not_to include("host-app.css")
        expect(last_response.body).to include("DemoButton")
      end

      # Fail-SAFE, not fail-blank: rendering through a layout that never calls
      # `ruact_js_assets` would emit a document with no bootstrap and no
      # payload. Under the `:auto` default that is the expected un-migrated
      # state, so it must degrade to the built-in shell — a working (if
      # unstyled) page — rather than serve a blank one.
      context "when the host layout never calls ruact_js_assets" do
        it "falls back to the built-in shell instead of serving a blank document" do
          get "/unwired-layout-demo/show"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).to include("__FLIGHT_DATA")
          expect(last_response.body).to include("DemoButton")
          expect(last_response.body).not_to include("host-app.css")
        end
      end

      # THE backward-compatibility guarantee, and the one the first cut of this
      # change broke (found in review): under `:auto` an unmigrated layout must
      # never be EXECUTED, only inspected. A pre-migration layout has never once
      # run on a ruact page, so it can reference state a ruact action never sets
      # — rendering it speculatively, just to discover it lacks the helper,
      # turns a working page into a 500 on an app that changed nothing.
      context "when the unmigrated layout would raise if it were rendered" do
        it "never executes it — the page still renders through the built-in shell" do
          get "/exploding-layout-demo/show"

          expect(last_response.status).to(eq(200),
                                          "expected the layout NOT to be rendered; got " \
                                          "#{last_response.status} body=#{last_response.body[0, 300]}")
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).to include("DemoButton")
        end
      end

      # A layout can carry `ruact_js_assets` and still be unusable: with no root
      # div, React boots with nothing to mount into and the page is silently
      # blank. Checking only for the payload marker accepted exactly this.
      context "when the layout has the assets but no root div to mount into" do
        it "falls back rather than serving a document React cannot mount into" do
          get "/rootless-layout-demo/show"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).not_to include("host-app.css")
          expect(last_response.body).to match(/id="root"/)
        end
      end

      # An app with no resolvable layout at all (API-shaped, or `layout false`)
      # must keep working: `layout: true` raises ArgumentError there, which
      # would have turned every such page into a 500 the moment this default
      # landed.
      context "when the controller has no resolvable layout" do
        it "renders the built-in shell rather than raising" do
          get "/demo/show"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).to include("DemoButton")
        end
      end

      context "when layout is configured false" do
        it "uses the built-in shell even though the layout is ready" do
          Ruact.configure do |c|
            c.manifest_path = ControllerRequestSpecSupport.manifest_path
            c.layout = false
          end

          get "/layout-demo/show"

          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).not_to include("host-app.css")
        end
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

    # Story 10.0 — implicit `default_render` must degrade gracefully on non-HTML
    # Accept. Exercised against an ivar-only GET page action (empty body) whose
    # conventional template exists, so the request traverses `default_render`'s
    # activation predicate (NOT a hand-written `ruact_render` like demo#show).
    describe "Story 10.0: default_render graceful degradation on non-HTML Accept", :story_10_0 do
      it "GET with Accept: */* renders the HTML shell (was a 500 pre-10.0) (AC1)" do
        # RED pre-fix: `*/*` → format.html? false, ruact_request? false → super →
        # Rails renders the .html.erb outside a ruact_render flow → raises
        # "__ruact_component__ called outside a ruact_render flow".
        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "*/*" }
        expect(last_response.status).to(eq(200),
                                        "expected 200, got #{last_response.status} body=#{last_response.body[0, 400]}")
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(last_response.body).to include("DemoButton")
        expect(last_response.body).not_to include("__ruact_component__ called outside a ruact_render flow")
      end

      it "GET with an empty Accept header (defaults to HTML) renders the HTML shell (AC1)" do
        # An empty Accept token parses to `[nil]` (not blank, not a concrete
        # type) — it must degrade to the HTML shell, never raise NoMethodError.
        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(last_response.body).to include("DemoButton")
      end

      it "GET with Accept: text/html renders the same HTML shell as */* (AC2)" do
        # AC2: the explicit text/html path is unchanged and the */* path now
        # yields the SAME shell. Normalize the per-request CSRF token (the only
        # request-varying bytes) before comparing.
        strip_csrf = ->(body) { body.gsub(/content="[^"]+"/, 'content="CSRF"') }

        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "text/html" }
        html_response = last_response.body
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(html_response).to include("DemoButton")

        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "*/*" }
        expect(strip_csrf.call(last_response.body)).to eq(strip_csrf.call(html_response))
      end

      it "GET with Accept: text/x-component returns a raw Flight payload (AC3)" do
        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/x-component")
        expect(last_response.body).to match(%r{\h+:I\[.*/DemoButton\.jsx})
      end

      it "GET with the Ruact-Request: 1 header returns a Flight payload (AC3)" do
        get "/implicit-demo/show", {}, { "HTTP_RUACT_REQUEST" => "1" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/x-component")
      end

      it "GET with concrete Accept: application/json bypasses RSC to super (AC4)" do
        # The concrete non-HTML format carries no html/wildcard accept, so
        # `default_render` must fall through to `super` (Rails default rendering).
        # With no JSON template and no respond_to, Rails raises an UnknownFormat /
        # MissingTemplate — NOT the ruact outside-flow 500. We only assert it is
        # NOT the ruact bug; Rails' exact choice of error is its own concern.
        error = nil
        begin
          get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "application/json" }
        rescue StandardError => e
          error = e
        end
        expect(error).not_to be_nil
        expect(error.message).not_to include("__ruact_component__ called outside a ruact_render flow")
        expect(error).to be_a(ActionController::ActionControllerError).or(be_a(ActionView::MissingTemplate))
      end

      it "GET with two concrete non-HTML types (application/json, application/xml) bypasses to super (AC4)" do
        # AC4's literal example: NEITHER member is html nor the wildcard, so the
        # predicate is false and the request must fall through to `super`.
        error = nil
        begin
          get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "application/json, application/xml" }
        rescue StandardError => e
          error = e
        end
        expect(error).not_to be_nil
        expect(error.message).not_to include("__ruact_component__ called outside a ruact_render flow")
      end

      it "GET with a mixed Accept that includes text/html (application/json, text/html) renders the shell" do
        # HTML is acceptable (listed explicitly) → membership predicate activates
        # the shell. default_render is only reached on an implicitly-rendered
        # action (no JSON representation to prefer), so serving the accepted HTML
        # is the sensible non-error outcome — and a 200, not the pre-10.0 500.
        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "application/json, text/html" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(last_response.body).to include("DemoButton")
      end

      it "GET with a concrete-then-wildcard Accept (application/json, */*) renders the shell" do
        get "/implicit-demo/show", {}, { "HTTP_ACCEPT" => "application/json, */*" }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(last_response.body).to include("DemoButton")
      end

      it "GET with a real browser Accept (text/html,...,*/*;q=0.8) renders the shell (AC2-adjacent)" do
        get "/implicit-demo/show", {}, {
          "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to include("text/html")
        expect(last_response.body).to include("DemoButton")
      end
    end
  end
end
