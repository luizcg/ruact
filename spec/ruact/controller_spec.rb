# frozen_string_literal: true

require "spec_helper"
require "active_support/concern"
# Re-run-5 (2026-05-15) — the `:current_user` inherited-helper clobber
# test creates a `Class.new(ActionController::Base)`, which requires
# `action_controller` to be loaded. Pre-Re-run-5 this test was the
# first thing in the suite to demand-load `action_controller`,
# which had the side effect of triggering `Rails::Application`'s
# class definition AFTER spec_helper's `require "ruact"` ran — so
# `Ruact::Railtie` never got loaded into the process and downstream
# specs that depend on the Railtie's `to_prepare` hook would behave
# inconsistently. Loading both explicitly here makes the order
# deterministic.
require "action_controller"
require "ruact"
require "ruact/controller"

module Ruact
  RSpec.describe Controller do
    let(:test_class) do
      Class.new do
        include Ruact::Controller

        attr_reader :request

        def initialize(fake_request)
          @request = fake_request
        end
      end
    end

    # Minimal test double — `headers` + `format` needed for the methods under test.
    # `format` must be a public struct member (not Kernel#format) so that
    # verify_partial_doubles can stub it in #default_render tests.
    let(:fake_request) { Struct.new(:headers, :format).new({}, nil) }
    let(:controller)   { test_class.new(fake_request) }

    describe "#ruact_manifest" do
      it "reads from Ruact.manifest (AC#6)" do
        test_manifest = ClientManifest.from_hash({})
        allow(Ruact).to receive(:manifest).and_return(test_manifest)
        expect(controller.send(:ruact_manifest)).to be test_manifest
      end
    end

    describe "#ruact_request?" do
      it "returns true when Accept: text/x-component" do
        fake_request.headers["Accept"] = "text/x-component"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns true when Accept header includes text/x-component alongside other types" do
        fake_request.headers["Accept"] = "text/x-component, */*"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns true when Ruact-Request: 1 header is set" do
        fake_request.headers["Ruact-Request"] = "1"
        expect(controller.send(:ruact_request?)).to be true
      end

      it "returns false when Accept: text/html" do
        fake_request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        expect(controller.send(:ruact_request?)).to be false
      end

      it "returns false when no Accept header is set" do
        expect(controller.send(:ruact_request?)).to be false
      end
    end

    describe "#default_render" do
      let(:html_format) { Class.new { def html? = true }.new }
      let(:json_format) { Class.new { def html? = false }.new }

      before do
        allow(controller).to receive(:ruact_template_exists?).and_return(true)
        allow(controller).to receive(:ruact_render)
      end

      it "calls ruact_render when format is HTML and template exists (AC#1)" do
        allow(fake_request).to receive(:format).and_return(html_format)
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "calls ruact_render for RSC requests (text/x-component) even without html? (AC#1)" do
        allow(fake_request).to receive(:format).and_return(json_format)
        fake_request.headers["Ruact-Request"] = "1"
        controller.send(:default_render)
        expect(controller).to have_received(:ruact_render)
      end

      it "does NOT call ruact_render when format is not HTML and not RSC (AC#5, AC#6 — FR26)" do
        allow(fake_request).to receive(:format).and_return(json_format)
        allow(controller).to receive(:ruact_render)
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:ruact_render)
      end

      it "does NOT call ruact_render when no template exists" do
        allow(controller).to receive(:ruact_template_exists?).and_return(false)
        allow(fake_request).to receive(:format).and_return(html_format)
        begin
          controller.send(:default_render)
        rescue StandardError
          nil
        end
        expect(controller).not_to have_received(:ruact_render)
      end
    end

    describe "#redirect_to" do
      # Build a class hierarchy so `super` inside the override can call a base implementation.
      # url_for and render must be defined for verify_partial_doubles to allow stubbing them.
      let(:redirect_test_class) do
        base = Class.new do
          def redirect_to(*)
            :super_called
          end

          def url_for(options)
            options.is_a?(String) ? options : "/"
          end

          def render(**_opts); end
        end
        Class.new(base) do
          include Ruact::Controller

          attr_reader :request

          def initialize(req)
            super()
            @request = req
          end
        end
      end

      let(:ruact_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({ "Accept" => "text/x-component" }, "localhost"))
      end
      let(:html_ctrl) do
        redirect_test_class.new(Struct.new(:headers, :host).new({}, "localhost"))
      end

      context "when RSC request with same-origin URL (AC #1, #5)" do
        before { allow(ruact_ctrl).to receive(:url_for).and_return("/posts/1") }

        it "calls render with a Flight redirect row (not a 302)" do
          allow(ruact_ctrl).to receive(:render)
          ruact_ctrl.send(:redirect_to, "/posts/1")
          expect(ruact_ctrl).to have_received(:render).with(
            plain: "0:{\"redirectUrl\":\"/posts/1\",\"redirectType\":\"push\"}\n",
            content_type: "text/x-component"
          )
        end

        it "redirect row matches the flight fixture (AC #5)" do
          rendered_plain = nil
          allow(ruact_ctrl).to receive(:render) { |opts| rendered_plain = opts[:plain] }
          ruact_ctrl.send(:redirect_to, "/posts/1")
          expect(rendered_plain).to match_flight_fixture("redirect_row")
        end
      end

      context "when RSC request with external URL (AC #3)" do
        before { allow(ruact_ctrl).to receive(:url_for).and_return("https://external.com/page") }

        it "does NOT emit a redirect row (falls back to super)" do
          allow(ruact_ctrl).to receive(:render)
          ruact_ctrl.send(:redirect_to, "https://external.com/page")
          expect(ruact_ctrl).not_to have_received(:render)
        end
      end

      context "when non-RSC request (AC #4)" do
        before { allow(html_ctrl).to receive(:url_for).and_return("/posts/1") }

        it "does NOT emit a redirect row (falls back to super)" do
          allow(html_ctrl).to receive(:render)
          html_ctrl.send(:redirect_to, "/posts/1")
          expect(html_ctrl).not_to have_received(:render)
        end
      end
    end

    describe "#ruact_html_shell" do
      # vite_tags requires Rails.env — stub it so we can test the shell structure.
      before { allow(controller).to receive(:vite_tags).and_return("") }

      let(:payload) { "0:[\"$\",\"div\",null,{}]\n" }

      it "returns a string containing window.__FLIGHT_DATA" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include("__FLIGHT_DATA")
      end

      it "wraps the payload in an IIFE push" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include("d.push(")
      end

      it "contains a root div#root element" do
        html = controller.send(:ruact_html_shell, payload)
        expect(html).to include('<div id="root">')
      end

      it "escapes </script> in the payload to prevent XSS breakout" do
        dangerous_payload = "0:\"</script><script>alert(1)</script>\"\n"
        html = controller.send(:ruact_html_shell, dangerous_payload)
        # The HTML must contain exactly ONE </script> — the real closing tag of the script block.
        # If the payload's </script> leaked through, there would be more than one.
        occurrences = html.scan("</script>")
        count = occurrences.length
        expect(count).to eq(1), "Expected 1 </script> (closing tag), found #{count}"
      end

      # Story 8.3 review R7 — the shell must surface the host's CSRF token
      # as a `<meta name="csrf-token">` tag so the JS runtime can forward
      # it as `X-CSRF-Token` on every `_makeRef` call. Without this,
      # standalone server actions (Story 8.3 AC5) — for which the gem
      # enforces CSRF itself via `protect_from_forgery with: :exception,
      # if: :dispatching_standalone?` — can never authenticate, because
      # the document has no token for the runtime to read.
      context "Story 8.3 — CSRF meta tag injection", :story_8_3 do
        # The bare `test_class` above is a minimal `include Ruact::Controller`
        # consumer with no `form_authenticity_token` surface (no Rails
        # request-forgery-protection module mixed in). Define a real method
        # on the class so `respond_to?(:form_authenticity_token, true)` is
        # true AND `verify_partial_doubles` lets us stub the return value.
        let(:csrf_test_class) do
          Class.new(test_class) do
            def form_authenticity_token
              "stub-default-token"
            end
          end
        end
        let(:csrf_controller) { csrf_test_class.new(fake_request) }

        it "embeds <meta name=\"csrf-token\" content=\"...\"> when the host exposes form_authenticity_token" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return("test-csrf-token-value")
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).to include('<meta name="csrf-token" content="test-csrf-token-value" />')
        end

        it "HTML-escapes the token value (defense against accidental quote injection)" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return('"quoted" & <evil>')
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).to include("&quot;quoted&quot; &amp; &lt;evil&gt;")
          expect(html).not_to include('"quoted" & <evil>')
        end

        it "omits the meta tag (renders empty string) when form_authenticity_token is not available " \
           "(e.g., a non-Rails spec context)" do
          # `controller` is the bare test_class without `form_authenticity_token`.
          html = controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end

        it "omits the meta tag when form_authenticity_token returns nil/empty" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_return("")
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end

        it "silently omits the meta tag if form_authenticity_token raises " \
           "(e.g., session middleware missing in a stripped-down test env)" do
          allow(csrf_controller).to receive(:form_authenticity_token).and_raise(StandardError, "no session")
          expect { csrf_controller.send(:ruact_html_shell, payload) }.not_to raise_error
          html = csrf_controller.send(:ruact_html_shell, payload)
          expect(html).not_to include('name="csrf-token"')
        end
      end
    end

    describe "ruact_action DSL macro (Story 8.1)", :story_8_1 do
      # The macro is class-level. Each example builds a fresh anonymous
      # controller class so registry state is per-example. The registry
      # itself is reset at the top of every example via Ruact.action_registry.clear!
      # to avoid leakage across spec runs.
      before { Ruact.action_registry.clear! }

      it "registers an action in Ruact.action_registry with the correct kind, controller, and block" do
        klass = Class.new do
          def self.name = "ExampleController"
          include Ruact::Controller

          ruact_action(:create_post) { |params| "created #{params[:title]}" }
        end

        entry = Ruact.action_registry.entries[:create_post]
        expect(entry).not_to be_nil
        expect(entry.ruby_symbol).to eq(:create_post)
        expect(entry.js_identifier).to eq("createPost")
        expect(entry.kind).to eq(:action)
        expect(entry.controller).to be(klass)
        expect(entry.block).to be_a(Proc)
      end

      it "defines the action symbol as a PUBLIC method (Rails action dispatch requires public) " \
         "with a thread-local guard that rejects non-endpoint invocations (review-batch 1 2026-05-14)" do
        klass = Class.new do
          def self.name = "ExampleController"
          include Ruact::Controller

          ruact_action(:create_post) { |params| "echo #{params[:title]}" }
        end

        instance = klass.allocate
        # Public (so ActionController#process can dispatch it through the
        # before_action chain when scoped `only: :create_post`).
        expect(instance.respond_to?(:create_post)).to be(true)
        # Direct call without the thread-local sentinel raises — closes the
        # wildcard-route exposure where a host's `get ":controller/:action"`
        # could otherwise reach the action via GET.
        expect { instance.send(:create_post) }.to raise_error(Ruact::Error, /can only be invoked through POST/)
      end

      it "raises ArgumentError when no block is given" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:create_post)
          end
        end.to raise_error(ArgumentError, /requires a block/)
      end

      it "raises Ruact::ConfigurationError with the AC7 prefix on invalid symbol shape" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:CreatePost) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /invalid server-function symbol :CreatePost in BadController/)
      end

      it "raises Ruact::ConfigurationError with the AC7 collision wording on within-registry duplicate js_identifier" do
        expect do
          Class.new do
            def self.name = "CollidingController"
            include Ruact::Controller

            ruact_action(:foo_bar)  { |_p| nil }
            ruact_action(:foo__bar) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /server-function naming collision.*"fooBar"/m)
      end

      it "raises Ruact::ConfigurationError when the symbol maps to a reserved JS word" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:delete) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /reserved/)
      end

      it "raises Ruact::ConfigurationError when the symbol clobbers a framework method " \
         "(review-batch 1 2026-05-14)" do
        # `:params` is defined on ActionController::Base via Metal — declaring
        # `ruact_action :params` would override the request-params accessor.
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:params) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /would clobber a framework method/)
      end

      it "raises ArgumentError on a zero-arity block (review-batch 1 2026-05-14)" do
        expect do
          Class.new do
            def self.name = "ExampleController"
            include Ruact::Controller

            ruact_action(:no_args) { "pong" }
          end
        end.to raise_error(ArgumentError, /must accept exactly one positional parameter/)
      end

      it "rejects a block with required keyword arguments (re-run-4 #4 — " \
         "block.parameters guard catches `do |p, required:|`)" do
        expect do
          Class.new do
            def self.name = "ExampleController"
            include Ruact::Controller

            ruact_action(:bad_kwargs) { |_params, required:| required }
          end
        end.to raise_error(ArgumentError, /no required keyword arguments/)
      end

      it "accepts optional keyword args alongside the positional (re-run-4 #4 — " \
         "`do |params, opt: nil|` is fine)" do
        expect do
          Class.new do
            def self.name = "ExampleController"
            include Ruact::Controller

            ruact_action(:opt_kwargs) { |_params, opt: nil| opt }
          end
        end.not_to raise_error
      end

      it "accepts a splat-arity block (do |*args|) since it tolerates one positional arg" do
        expect do
          Class.new do
            def self.name = "ExampleController"
            include Ruact::Controller

            ruact_action(:splat_args) { |*args| args.first }
          end
        end.not_to raise_error
      end

      it "rejects a String argument (re-run-2 #4 — String key would 404 on dispatch)" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action("create_post") { |_p| nil }
          end
        end.to raise_error(ArgumentError, /requires a Symbol/)
      end

      it "rejects clobber of a method already defined on the host class itself " \
         "(re-run-2 #3 — guard extended from framework methods to host methods)" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            def index; end
            ruact_action(:index) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /would clobber an existing method/)
      end

      it "rejects clobber of an INHERITED app helper like :current_user " \
         "(re-run-3 #2 — guard extended from own-class to inherited app methods)" do
        # Stand-in for `ApplicationController` defining `current_user` and
        # subclasses inheriting it; declaring `ruact_action :current_user`
        # would silently override the auth helper.
        app_controller = Class.new(ActionController::Base) do
          def current_user; end
          def authenticate_user!; end
        end
        expect do
          Class.new(app_controller) do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:current_user) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /would clobber an inherited helper/)
      end

      it "rejects clobber of CSRF callback :verify_authenticity_token " \
         "(re-run-5 #2 — added to FRAMEWORK_RESERVED_METHODS)" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:verify_authenticity_token) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /would clobber a framework method/)
      end

      it "rejects a block with MULTIPLE required positional parameters " \
         "(re-run-5 #3 — `do |a, b|` silently received nil for `b`)" do
        expect do
          Class.new do
            def self.name = "ExampleController"
            include Ruact::Controller

            ruact_action(:two_positional) { |_a, _b| nil }
          end
        end.to raise_error(ArgumentError, /must accept exactly one positional/)
      end

      it "rejects clobber of Kernel#send / Kernel#public_send " \
         "(re-run-3 #2 — added to FRAMEWORK_RESERVED_METHODS)" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_action(:send) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /would clobber a framework method/)
      end

      it "rejects clobber of an INHERITED ActionController::Base method like :status " \
         "(re-run-6 #2 — denylist widened from hardcoded set to all framework methods - Object methods)" do
        expect do
          Class.new do
            def self.name = "BadController"

            include Ruact::Controller

            ruact_action(:status) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError,
                           /would clobber an inherited ActionController::Base method/)
      end

      it "rejects a LATER def that overrides a previously-registered " \
         "ruact_action method in the same class body (re-run-6 #1 — method_added hook)" do
        # The macro defines the action method; a later `def create_post; end`
        # would silently shadow it, causing host_class.dispatch to skip the
        # sentinel guard and run the user's later body. Detect at class-load
        # time via method_added hook so the error is loud at boot.
        expect do
          Class.new do
            def self.name = "BadController"

            include Ruact::Controller

            ruact_action(:create_post) { |_p| "from macro" }

            def create_post
              "from later def"
            end
          end
        end.to raise_error(Ruact::ConfigurationError,
                           /registered by `ruact_action :create_post` and then re-defined/)
      end

      it "preserves a pre-existing `method_added` hook on the host class " \
         "(re-run-7 #1 — prepended Module instead of define_method clobber)" do
        # Apps and concerns commonly install `method_added` for
        # instrumentation, DSL bookkeeping (`attr_*` style helpers), or
        # auditing. If the gem replaced the host's `method_added` instead
        # of chaining through it, those concerns would stop firing as soon
        # as the first `ruact_action` runs.
        recorded = []
        klass = Class.new do
          def self.name = "ExampleController"

          singleton_class.define_method(:method_added) do |meth|
            recorded << meth
            super(meth)
          end

          include Ruact::Controller

          ruact_action(:create_post) { |_p| "from macro" }

          def helper_method
            :ok
          end
        end

        # Both the macro-defined :create_post AND the later `def helper_method`
        # should have been observed by the host's `method_added`.
        expect(recorded).to include(:create_post, :helper_method)
        # The action method is still registered and dispatch-guarded.
        expect(klass.allocate.respond_to?(:create_post)).to be(true)
      end
    end

    describe "ruact_action cross-controller collisions (Story 8.1 — re-run-3)" do
      before { Ruact.action_registry.clear! }

      it "raises Ruact::ConfigurationError when the SAME symbol is declared on TWO controllers " \
         "(re-run-3 #1 — silent overwrite would route to whichever loaded last)" do
        Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_action(:create_post) { |_p| nil }
        end

        expect do
          Class.new do
            def self.name = "AdminPostsController"
            include Ruact::Controller

            ruact_action(:create_post) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /declared in BOTH/)
      end
    end

    describe "ruact_query DSL macro (Story 9.1)", :aggregate_failures, :story_9_1 do
      # The macro is class-level. Each example builds a fresh anonymous
      # controller class so registry state is per-example. BOTH registries
      # are reset at the top of every example so cross-registry collision
      # checks (which look at action_registry + query_registry together) see
      # a clean slate.
      before do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!
      end

      it "registers a query in Ruact.query_registry with kind: :query, the right controller, and " \
         "the block verbatim (AC1 — Story 9.1)" do
        klass = Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_query(:categories) { |_params| [{ value: 1, label: "Books" }] }
        end

        entry = Ruact.query_registry.entries[:categories]
        expect(entry).not_to be_nil
        expect(entry.ruby_symbol).to eq(:categories)
        expect(entry.js_identifier).to eq("categories")
        expect(entry.kind).to eq(:query)
        expect(entry.controller).to be(klass)
        expect(entry.block).to be_a(Proc)
      end

      it "does NOT also register the query in the action registry (Story 9.1 — registries " \
         "stay disjoint at the macro layer)" do
        Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_query(:categories) { |_p| [] }
        end

        expect(Ruact.action_registry.entries).to eq({})
        expect(Ruact.query_registry.entries[:categories]).not_to be_nil
      end

      it "defines the query symbol as a PUBLIC method with the thread-local guard that " \
         "rejects non-endpoint invocations (Story 9.1 parity with action dispatch)" do
        klass = Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_query(:categories) { |_p| [{ value: 1 }] }
        end

        instance = klass.allocate
        expect(instance.respond_to?(:categories)).to be(true)
        expect { instance.send(:categories) }.to raise_error(Ruact::Error, /can only be invoked through POST/)
      end

      it "raises ArgumentError when no block is given (Story 9.1)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:categories)
          end
        end
        expect(&define_bad).to raise_error(ArgumentError) do |error|
          expect(error.message).to include("ruact_query :categories requires a block")
          expect(error.message).to include("do |params| ... end")
        end
      end

      it "raises Ruact::ConfigurationError with the naming-bridge prefix on an invalid symbol shape " \
         "(Story 9.1 — bridge applies identically to queries)" do
        expect do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:CategoriesIndex) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError,
                           /invalid server-function symbol :CategoriesIndex in BadController/)
      end

      it "raises Ruact::ConfigurationError on a within-query-registry duplicate JS identifier (Story 9.1)" do
        expect do
          Class.new do
            def self.name = "CollidingController"
            include Ruact::Controller

            ruact_query(:foo_bar)  { |_p| nil }
            ruact_query(:foo__bar) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError, /server-function naming collision.*"fooBar"/m)
      end

      it "raises Ruact::ConfigurationError when the symbol clobbers a framework method like :params " \
         "(Story 9.1 — parity with action clobber guard, ruact_query suffix on the suggestion)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:params) { |_p| nil }
          end
        end
        expect(&define_bad).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("ruact_query :params would clobber a framework method")
          expect(error.message).to include(":params_query")
        end
      end

      it "raises ArgumentError on a zero-arity block (Story 9.1 — block.parameters guard)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:no_args) { "pong" }
          end
        end
        expect(&define_bad).to raise_error(ArgumentError) do |error|
          expect(error.message).to include("ruact_query :no_args block")
          expect(error.message).to include("must accept exactly one positional parameter")
        end
      end

      it "rejects a block with required keyword arguments (Story 9.1 — block.parameters keyreq guard)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:bad_kwargs) { |_params, required:| required }
          end
        end
        expect(&define_bad).to raise_error(ArgumentError) do |error|
          expect(error.message).to include("ruact_query :bad_kwargs block")
          expect(error.message).to include("no required keyword arguments")
        end
      end

      it "accepts optional keyword args alongside the positional (Story 9.1 — parity with action)" do
        expect do
          Class.new do
            def self.name = "PostsController"
            include Ruact::Controller

            ruact_query(:opt_kwargs) { |_params, opt: nil| opt }
          end
        end.not_to raise_error
      end

      it "rejects a String argument (Story 9.1 — Symbol-only guard)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query("categories") { |_p| nil }
          end
        end
        expect(&define_bad).to raise_error(ArgumentError) do |error|
          expect(error.message).to include("ruact_query requires a Symbol")
          expect(error.message).to include("ruact_query :categories")
        end
      end

      it "rejects clobber of a method already defined on the host class itself (Story 9.1)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"
            include Ruact::Controller

            def index; end
            ruact_query(:index) { |_p| nil }
          end
        end
        expect(&define_bad).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("ruact_query :index would clobber an existing method")
          expect(error.message).to include("server query")
          expect(error.message).to include(":index_remote")
        end
      end

      it "rejects clobber of an INHERITED app helper like :current_user (Story 9.1)" do
        app_controller = Class.new(ActionController::Base) do
          def current_user; end
        end
        define_bad = lambda do
          Class.new(app_controller) do
            def self.name = "BadController"
            include Ruact::Controller

            ruact_query(:current_user) { |_p| nil }
          end
        end
        expect(&define_bad).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("ruact_query :current_user would clobber an inherited helper")
          expect(error.message).to include(":current_user_remote")
        end
      end

      it "rejects clobber of an INHERITED ActionController::Base method like :status (Story 9.1)" do
        expect do
          Class.new do
            def self.name = "BadController"

            include Ruact::Controller

            ruact_query(:status) { |_p| nil }
          end
        end.to raise_error(Ruact::ConfigurationError,
                           /ruact_query :status would clobber an inherited ActionController::Base method/)
      end

      it "rejects a LATER def that overrides a previously-registered ruact_query method " \
         "in the same class body (Story 9.1 — method_added hook resolves dsl_name back to ruact_query)" do
        define_bad = lambda do
          Class.new do
            def self.name = "BadController"

            include Ruact::Controller

            ruact_query(:categories) { |_p| [] }

            def categories
              "from later def"
            end
          end
        end
        expect(&define_bad).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("registered by `ruact_query :categories` and then re-defined")
          expect(error.message).to include("macro-defined query")
          expect(error.message).to include("rename the ruact_query")
        end
      end

      it "preserves a pre-existing `method_added` hook on the host class when ruact_query installs " \
         "its own (Story 9.1 — parity with re-run-7 action behavior)" do
        recorded = []
        klass = Class.new do
          def self.name = "PostsController"

          singleton_class.define_method(:method_added) do |meth|
            recorded << meth
            super(meth)
          end

          include Ruact::Controller

          ruact_query(:categories) { |_p| [] }

          def helper_method
            :ok
          end
        end

        expect(recorded).to include(:categories, :helper_method)
        expect(klass.allocate.respond_to?(:categories)).to be(true)
      end

      it "resets `@__ruact_being_defined_by_dsl` even when `define_method` raises " \
         "(Story 9.1 F5 — ensure-block prevents the sentinel from leaking `true` into the next " \
         "macro call and silently disarming the re-definition guard)" do
        # Simulate `define_method` raising mid-flight by giving the host a
        # `method_added` hook that vetoes a specific symbol. Without the
        # ensure, the gem's @__ruact_being_defined_by_dsl would stay `true`
        # and the very next `def #{symbol}` in the class body would no
        # longer trip the gem's re-definition raise.
        klass = Class.new do
          def self.name = "PostsController"

          singleton_class.define_method(:method_added) do |meth|
            raise "host veto" if meth == :poisoned

            super(meth)
          end

          include Ruact::Controller
        end

        expect do
          klass.ruact_query(:poisoned) { |_p| [] }
        end.to raise_error(RuntimeError, /host veto/)

        # Sentinel must be `false` so a SUBSEQUENT macro call observes the
        # correct state for its own re-definition guard.
        expect(klass.instance_variable_get(:@__ruact_being_defined_by_dsl)).to be(false)

        # Independent registration of a different symbol must continue to
        # work normally — proves the host class is not corrupted.
        expect do
          klass.ruact_query(:tags) { |_p| [] }
        end.not_to raise_error
        expect(Ruact.query_registry.entries[:tags]).not_to be_nil
      end

      it "raises Ruact::ConfigurationError when the SAME ruact_query symbol is declared on TWO " \
         "controllers (Story 9.1 — silent overwrite would route to whichever loaded last)" do
        Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_query(:categories) { |_p| [] }
        end

        expect do
          Class.new do
            def self.name = "AdminPostsController"
            include Ruact::Controller

            ruact_query(:categories) { |_p| [] }
          end
        end.to raise_error(Ruact::ConfigurationError, /declared in BOTH/)
      end
    end

    describe "ruact_query × ruact_action cross-registry collisions (Story 9.1)", :aggregate_failures, :story_9_1 do
      before do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!
      end

      it "raises Ruact::ConfigurationError at class load when the SAME controller declares " \
         "both `ruact_action :foo` and `ruact_query :foo` (Story 9.1 F2 — without this guard the " \
         "second declaration silently overwrote the dispatch method; the Snapshot collision " \
         "detector would catch it LATER but the class is transiently broken in between)" do
        define_both = lambda do
          Class.new do
            def self.name = "PostsController"
            include Ruact::Controller

            ruact_action(:create_post) { |_p| { ok: "from action" } }
            ruact_query(:create_post)  { |_p| { ok: "from query"  } }
          end
        end

        expect(&define_both).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("ruact_query :create_post")
          expect(error.message).to include("`ruact_action :create_post`")
          expect(error.message).to include("PostsController")
          expect(error.message).to include("queries are nouns")
          expect(error.message).to include("actions are verbs")
        end
      end

      it "the cross-DSL guard also catches the opposite order — `ruact_query` first, then " \
         "`ruact_action` (Story 9.1 F2 — order-independent)" do
        define_both = lambda do
          Class.new do
            def self.name = "PostsController"
            include Ruact::Controller

            ruact_query(:create_post)  { |_p| nil }
            ruact_action(:create_post) { |_p| nil }
          end
        end

        expect(&define_both).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to include("ruact_action :create_post")
          expect(error.message).to include("`ruact_query :create_post`")
        end
      end

      it "re-registering the SAME DSL with the SAME symbol on the SAME controller is NOT a " \
         "clobber (legitimate dev-mode reload after registry clear; Story 9.1 F2 — guard only " \
         "fires when DSL kind differs)" do
        klass = Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_action(:create_post) { |_p| nil }
        end

        expect do
          klass.class_eval { ruact_action(:create_post) { |_p| nil } }
        end.not_to raise_error
      end

      it "Snapshot.functions_payload raises Ruact::ConfigurationError with the naming-convention " \
         "suffix when an action and a query on DIFFERENT controllers collide on the JS identifier " \
         "(Story 9.1 AC3 — end-to-end through the macros)" do
        Class.new do
          def self.name = "PostsController"
          include Ruact::Controller

          ruact_action(:create_post) { |_p| nil }
        end
        Class.new do
          def self.name = "AdminPostsController"
          include Ruact::Controller

          ruact_query(:create_post) { |_p| nil }
        end

        run_payload = -> { Ruact::ServerFunctions::Snapshot.functions_payload(Ruact.action_registry, Ruact.query_registry) }
        expect(&run_payload).to raise_error(Ruact::ConfigurationError) do |error|
          expect(error.message).to start_with("server-function naming collision:")
          expect(error.message).to include(":create_post (in PostsController)")
          expect(error.message).to include(":create_post (in AdminPostsController)")
          expect(error.message).to include("Convention: queries should be nouns")
          expect(error.message).to include("actions should be verbs")
        end
      end
    end
  end
end
