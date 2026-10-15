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
require "stringio"
require "logger"
require "tmpdir"
require "fileutils"
require "pathname"
require "active_model"
require "ruact/testing"

# Ruact::Controller is normally loaded by the Railtie's `ruact.load_controller`
# initializer at app boot. This spec instantiates a Rails::Application but does
# not depend on initializer ordering, so we load the concern explicitly.
require "ruact/controller"

# Test-support helpers and demo controller — top-level so the Rails routes
# resolver finds them. Defined before the describe block so the controller
# class exists when routes are appended.
module ControllerRequestSpecSupport
  # Story 17.0i — the status demos' POST routes (path, controller#action).
  STATUS_DEMO_ROUTES = [
    *%w[create_action create_string create_hash create_template create_locals create_json create_plain
        create_other_folder explicit create_respond_to create_no_status create_delegated redirect_delegated
        create_scaffold_style create_with_location create_formats_html create_formats_json create_formats_nil
        create_pdf create_variant create_locale create_assigns create_alert create_prefixes
        create_redirect_respond_to]
      .map { |action| ["/status-demo/#{action}", "status_demo##{action}"] },
    ["/status-pages-demo/create", "status_pages_demo#create"],
    ["/status-demo/create_with_layout", "status_demo#create_with_layout"],
    ["/status-plain-demo/create", "status_plain_demo#create"],
    ["/layout-demo/create_unprocessable", "layout_demo#create_unprocessable"],
    ["/ghost-layout-demo/create_unprocessable", "ghost_layout_demo#create_unprocessable"],
    ["/unwired-layout-demo/create_unprocessable", "unwired_layout_demo#create_unprocessable"],
    ["/status-live-demo/create", "status_live_demo#create"],
    ["/status-rescue-demo/create", "status_rescue_demo#create"]
  ].freeze

  # Story 17-0j — respond_to on a router request (GET routes).
  RESPOND_TO_GET_ROUTES = [
    *%w[show_respond_to show_json_only show_inner_unknown]
      .map { |action| ["/status-demo/#{action}", "status_demo##{action}"] },
    ["/auth-demo/show", "auth_demo#show"]
  ].freeze

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
                                   },
                                   "Card" => { "id" => "/Card.jsx", "name" => "Card", "chunks" => ["/Card.jsx"] }
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

      # Suspense boundaries, rendered whole and through ActionController::Live.
      app_class.routes.append do
        get "/suspense-demo/show", to: "controller_request_spec_support/suspense_demo#show"
        get "/suspense-live-demo/show", to: "controller_request_spec_support/suspense_live_demo#show"
        # Story 19-1 — `ruact_streaming`.
        (%w[edit] + ControllerRequestSpecSupport::STREAMING_DEMO_PAGES).each do |action|
          get "/streaming-demo/#{action}", to: "controller_request_spec_support/streaming_demo##{action}"
        end
        # An endpoint whose route names no action.
        get "/streaming-direct", to: ControllerRequestSpecSupport::StreamingDemoController.action(:show)
        get "/streaming-direct-edit", to: ControllerRequestSpecSupport::StreamingDemoController.action(:edit)
        # Story 19-2 — fragment caching.
        %w[components suspense suspense_in_place].each do |action|
          get "/caching-demo/#{action}", to: "controller_request_spec_support/caching_demo##{action}"
        end
      end
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
          # Story 18-2 — a component with children, through ActionView.
          get "/children-demo/show", to: "controller_request_spec_support/children_demo#show"
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
          get "/ghost-layout-demo/show", to: "controller_request_spec_support/ghost_layout_demo#show"
          # Story 17.0f — a plain Rails page through the SAME host layout.
          get "/plain-layout-demo/show", to: "controller_request_spec_support/plain_layout_demo#show"
          # Story 17.0i — a ruact page answers with a status.
          STATUS_DEMO_ROUTES.each { |(path, target)| post path, to: "controller_request_spec_support/#{target}" }
          get "/status-demo/new", to: "controller_request_spec_support/status_demo#new"
          RESPOND_TO_GET_ROUTES.each { |(path, target)| get path, to: "controller_request_spec_support/#{target}" }
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

  # Story 18-2 — a client component with children: ERB content (escaped
  # output, a loop of components, a partial) evaluated in place.
  class ChildrenDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def show
      @title = "Hi"
      @body  = "<b>not markup</b>"
      @likes = [1, 2]
      ruact_render
    end
  end

  # A page with Suspense boundaries, rendered whole and row by row
  # (ActionController::Live): the content between the tags is evaluated in the
  # view, and only what it writes is content.
  class SuspenseDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def show = ruact_render
  end

  class SuspenseLiveDemoController < ActionController::Base
    include ActionController::Live
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def show = ruact_render(template: "controller_request_spec_support/suspense_demo/show")
  end

  # Story 19-1 — what a template saw, and when: `record(:one, response.committed?)`
  # in a block says whether the shell had been sent when the block ran.
  def self.events
    @events ||= []
  end

  def self.record(name, committed)
    events << [name, committed]
    nil
  end

  # Story 19-1/19-2 — the pages of StreamingDemoController that stream.
  STREAMING_DEMO_PAGES = %w[show plain raising slow delayed late_write leased quiet after_raises positions
                            capture empty content_for partials].freeze

  # Story 19-1 — `ruact_streaming`: the declared actions send their page as it
  # renders; `edit` (the same template) does not.
  class StreamingDemoController < ActionController::Base
    include Ruact::Controller

    ruact_streaming only: STREAMING_DEMO_PAGES

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def show = ruact_render

    def edit
      ControllerRequestSpecSupport.record(:thread, Thread.current)
      ruact_render(template: "controller_request_spec_support/streaming_demo/show")
    end

    def plain = ruact_render
    def raising = ruact_render
    def slow = ruact_render
    def delayed = ruact_render
    def late_write = ruact_render
    def quiet = ruact_render
    def positions = ruact_render
    def capture = ruact_render
    def empty = ruact_render
    def content_for = ruact_render
    def partials = ruact_render

    # Story 19-2 (AC6) — an after_action that raises once the page was sent.
    after_action(only: :after_raises) { raise ArgumentError, "after the page" }

    def after_raises = ruact_render(template: "controller_request_spec_support/streaming_demo/quiet")

    # A connection taken outside a block, as `Model.connection` takes one.
    def leased
      ::ActiveRecord::Base.lease_connection.select_value("SELECT 1")
      ruact_render(template: "controller_request_spec_support/streaming_demo/plain")
    end
  end

  # Story 19-2 (AC9) — fragment caching around client components and
  # <Suspense>: the cached HTML holds markers of the render that wrote it.
  class CachingDemoController < ActionController::Base
    include Ruact::Controller

    ruact_streaming only: :suspense

    self.perform_caching = true
    self.cache_store = ActiveSupport::Cache::MemoryStore.new

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)

    def components = ruact_render
    def suspense = ruact_render
    def suspense_in_place = ruact_render(template: "controller_request_spec_support/caching_demo/suspense")
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

  # Story 17.0i — the Rails idiom for a failed save, on a ruact page. The 422
  # symbol differs across the Rack versions of the CI matrix
  # (`:unprocessable_entity` on 2.2, `:unprocessable_content` on 3.1+, where the
  # old name warns): take the one this Rack knows.
  UNPROCESSABLE = Rack::Utils::SYMBOL_TO_STATUS_CODE.key(422)

  class StatusDemoController < ActionController::Base
    include Ruact::Controller

    def new; end
    def create_action = render(:new, status: UNPROCESSABLE)
    def create_string = render("new", status: 422)
    def create_hash = render(action: :new, status: 422)
    def create_template = render(template: "controller_request_spec_support/status_demo/new", status: 422)
    def create_locals = render(:with_locals, locals: { label: "from-locals" }, status: 422)
    def create_json = render(json: { ok: false }, status: 422)
    def create_plain = render(plain: "nope", status: 422)
    def create_other_folder = render(template: "controller_request_spec_support/implicit_demo/show", status: 422)
    def explicit = ruact_render(template: "controller_request_spec_support/status_demo/new", status: UNPROCESSABLE)
    def create_respond_to = respond_to { |format| format.html { render :new, status: 422 } }
    def create_no_status = render(:new)

    # Review R1 — the stock Rails scaffold: the JSON branch renders `show`, and
    # `show` has a JSON template next to the ruact page. Rails' negotiated
    # format decides which one renders, not the Accept header's `*/*`.
    def create_scaffold_style
      respond_to do |format|
        format.html { render :new, status: 422 }
        format.json { render :show, status: :created, location: "/status-demo/1" }
      end
    end

    # Story 17-0j — the shapes Rails' scaffold writes.
    def show_respond_to
      respond_to do |format|
        format.html
        format.json { render json: { page: "json" } }
      end
    end

    def show_json_only = respond_to { |format| format.json { render json: { page: "json" } } }

    # An UnknownFormat raised INSIDE a chosen branch is the app's, not ruact's.
    def show_inner_unknown = respond_to { |format| format.html { raise ActionController::UnknownFormat, "inner" } }

    def create_redirect_respond_to
      respond_to do |format|
        format.html { redirect_to "/status-demo/new" }
        format.json { head :created }
      end
    end

    def create_with_location = render(:new, status: 201, location: "/status-demo/1")
    def create_with_layout = render(:new, layout: "no_such_layout", status: 422)
    # Review R2 — `formats:` as Rails takes it: a single value, not only an Array.
    def create_formats_html = render(:new, formats: :html, status: 422)
    def create_formats_json = render(:show, formats: :json, status: 201)
    def create_formats_nil = render(:new, formats: nil, status: 422)

    # Review R2 — an option ruact does not know (wicked_pdf's `pdf:`) is not
    # ruact's to answer.
    # Review R3 — options Rails honours on a template render, honoured here too.
    def create_variant = render(:new, variant: :phone, status: 422)
    def create_locale = render(:new, locale: :en, status: 422)
    def create_assigns = render(:with_assigns, assigns: { assigned: "from-assigns" }, status: 422)
    # Review R3 — a key Rails ignores in silence (it is not the flash).
    def create_alert = render(:new, status: 422, alert: "Could not save")
    # Review R4 — `prefixes:` names another folder's template; ruact must not
    # render its own `show` in its place.
    def create_prefixes = render(:show, prefixes: ["controller_request_spec_support/implicit_demo"], status: 422)

    def create_pdf
      render(pdf: "report", template: "controller_request_spec_support/status_demo/new",
             formats: [:html])
    end

    # The `responders` gem (Devise's `respond_with`) calls `controller.render`
    # and `controller.redirect_to` with an explicit receiver: both must stay as
    # public as Rails makes them.
    def create_delegated = Delegator.new(self).render_new
    def redirect_delegated = Delegator.new(self).redirect_home
  end

  Delegator = Struct.new(:controller) do
    def render_new = controller.render(:new, status: 422)
    def redirect_home = controller.redirect_to("/status-demo/new")
  end

  # Story 17-0j review — an auth callback prepended AFTER the concern was
  # included runs before a before_action ruact prepends; it still gets the
  # negotiated format (ruact negotiates in process_action).
  class AuthDemoController < ActionController::Base
    include Ruact::Controller

    prepend_before_action :require_login

    def show; end

    private

    def require_login
      respond_to do |format|
        format.html { redirect_to "/status-demo/new" }
        format.json { head :unauthorized }
      end
    end
  end

  # Story 17.0i — a streaming controller: the Flight rows go out as they are
  # written, so the status has to be set before the first one.
  class StatusLiveDemoController < ActionController::Base
    include ActionController::Live
    include Ruact::Controller

    def create = render(:new, status: 422)
  end

  # Story 17.0i — no `include Ruact::Controller` at all: the view helper is
  # global, so the error must say to include the concern, not to call a
  # `ruact_render` this controller does not have.
  class StatusPlainDemoController < ActionController::Base
    def create = render(template: "controller_request_spec_support/implicit_demo/show", status: 422)
  end

  # Story 17.0i review R4 — a render ruact declined (an `alert:`) raises, and a
  # `rescue_from` renders another template: the second error must not repeat
  # the first render's explanation.
  class StatusRescueDemoController < ActionController::Base
    include Ruact::Controller

    rescue_from RuntimeError, with: :render_fallback

    def create = render(:boom, status: 422, alert: "x")

    private

    def render_fallback(_error) = render(template: "controller_request_spec_support/implicit_demo/show")
  end

  # Story 17.0i — `new` is not among the declared pages, so its template is not
  # a ruact page here: Rails renders it, and the component in it fails loudly.
  class StatusPagesDemoController < ActionController::Base
    include Ruact::Controller

    ruact_pages only: %i[show]

    def show; end
    def create = render(:new, status: 422)
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

    # Story 17.0i — the status survives this document branch.
    def create_unprocessable = ruact_render(template: "controller_request_spec_support/layout_demo/show", status: 422)
  end

  # Story 17.0f — whole-app mode: the app's layout calls ruact_head_assets and
  # ALSO renders pages ruact never touched. Those must not carry the Turbo meta.
  class PlainLayoutDemoController < ActionController::Base
    include Ruact::ViewHelper

    helper Ruact::ViewHelper
    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "ruact_host"

    def show
      render html: "<p>plain page</p>".html_safe, layout: "ruact_host"
    end
  end

  # An unmigrated layout that RAISES if rendered (it reads an ivar a ruact
  # action never sets). With the default config ruact must never execute it.
  class ExplodingLayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "exploding_host"

    def show
      ruact_render
    end
  end

  # Declares a layout that does not exist. `_default_layout` hands back the
  # String path WITHOUT checking, so "not nil" read as resolvable and the render
  # raised MissingTemplate instead of degrading.
  class GhostLayoutDemoController < ActionController::Base
    include Ruact::Controller

    append_view_path File.expand_path("../fixtures/story_7_9_views", __dir__)
    layout "no_such_host"

    def show
      ruact_render
    end

    # Story 17.0i — the status survives this document branch.
    def create_unprocessable
      ruact_render(template: "controller_request_spec_support/ghost_layout_demo/show",
                   status: 422)
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

    # Story 17.0i — the status survives this document branch.
    def create_unprocessable
      ruact_render(template: "controller_request_spec_support/unwired_layout_demo/show",
                   status: 422)
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

# Story 17.0i — conventional templates for the status demos.
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_demo", "new", <<~ERB
    <div>
      <DemoButton label={"status-new"} errors={ruact_errors} />
    </div>
  ERB
)
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_demo", "show_respond_to", %(<DemoButton label={"respond-to-page"} />\n)
)
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_demo", "with_locals", <<~ERB
    <div>
      <DemoButton label={label} />
    </div>
  ERB
)
STATUS_DEMO_VIEWS = ControllerRequestSpecSupport.app_root.join("app/views/controller_request_spec_support/status_demo")
File.write(STATUS_DEMO_VIEWS.join("new.html+phone.erb"), %(<DemoButton label={"status-new-phone"} />\n))
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_rescue_demo", "boom", %(<% raise "boom" %>\n)
)
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_demo", "with_assigns", %(<DemoButton label={@assigned} />\n)
)
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_live_demo", "new", <<~ERB
    <div>
      <DemoButton label={"status-new"} />
    </div>
  ERB
)
ControllerRequestSpecSupport.write_view(
  "controller_request_spec_support/status_demo", "show", <<~ERB
    <div>
      <DemoButton label={"status-show"} />
    </div>
  ERB
)
# Review R1 — templates of their own, so an action that renders `json:` or
# `plain:` WOULD be taken for a page if the renderer exclusion broke.
%w[create_json create_plain].each do |action|
  ControllerRequestSpecSupport.write_view(
    "controller_request_spec_support/status_demo", action, %(<DemoButton label={"#{action}-page"} />\n)
  )
end
File.write(
  ControllerRequestSpecSupport.app_root.join("app/views/controller_request_spec_support/status_demo/show.json.erb"),
  %({"json":"show"})
)
%w[show new].each do |action|
  ControllerRequestSpecSupport.write_view(
    "controller_request_spec_support/status_pages_demo", action, <<~ERB
      <div>
        <DemoButton label={"pages-#{action}"} />
      </div>
    ERB
  )
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

    # Reads the whole body, then closes it, as a client does, over HTTP/1.1.
    # Rack::Test speaks HTTP/1.0, where Live gives an ordinary response and a
    # page renders whole, without streaming (Story 19-1, review R3).
    def read_streamed(path, headers = {})
      status, response_headers, body = app.call(Rack::MockRequest.env_for(path, headers))
      read = +""
      body.each { |chunk| read << chunk }
      Rack::MockResponse.new(status, response_headers, [read])
    ensure
      body.close if body.respond_to?(:close)
    end

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
    #
    # The opt-in is EXPLICIT (`Ruact.config.layout`). ruact used to infer
    # readiness from the layout itself; three review rounds each found another
    # template shape that fooled the inference, so the question is no longer
    # asked. These examples pin both halves: nothing happens without the config,
    # and everything happens with it.
    describe "the layout owns the document" do
      def configure_layout(value)
        Ruact.configure do |c|
          c.manifest_path = ControllerRequestSpecSupport.manifest_path
          c.layout = value
        end
      end

      # The whole backward-compatibility story, and it is now structural rather
      # than argued: with the default config ruact never looks at, resolves, or
      # renders a layout at all.
      context "with the default configuration (layout = false)" do
        it "renders the built-in shell, exactly as before the layout path existed" do
          get "/layout-demo/show"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).not_to include("host-app.css")
          expect(last_response.body).to include("DemoButton")
        end

        # Story 17.0f — the shell is a ruact document too.
        it "tells Turbo Drive to reload rather than swap the shell in", :story_17_0f do
          get "/layout-demo/show"

          expect(last_response.body).to include(%(<meta name="turbo-visit-control" content="reload">))
        end

        # This layout raises if it is rendered (it reads an ivar a ruact action
        # never sets) — the shape of a real pre-migration app. Nothing may
        # execute it.
        it "never executes an unmigrated layout, so a working page cannot become a 500" do
          get "/exploding-layout-demo/show"

          expect(last_response.status).to(eq(200),
                                          "expected the layout NOT to be rendered; got " \
                                          "#{last_response.status} body=#{last_response.body[0, 300]}")
          expect(last_response.body).to include("Rails RSC")
        end
      end

      # Story 17.0b — `"ruact"` names the layout the GEM ships; its view path is
      # appended by the Railtie. This app boots WITHOUT the Railtie (the concern
      # is required by hand at the top of this file), so here the path never
      # arrives — the one way "ruact's own layout is missing" happens. It has to
      # degrade and say so in terms of the Railtie, not tell the developer to
      # edit a layout they never wrote. The resolving path is proven by
      # spec/ruact/gem_layout_boot_spec.rb, which boots through the Railtie.
      context "when config.layout is \"ruact\" but the gem's view path never reached the controller",
              :story_17_0b do
        before { configure_layout("ruact") }

        it "degrades to the shell and names the Railtie as the thing to check", :aggregate_failures do
          log = StringIO.new
          original = ActionController::Base.logger
          ActionController::Base.logger = Logger.new(log)
          begin
            get "/layout-demo/show"
          ensure
            ActionController::Base.logger = original
          end

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(log.string).to include("layouts/ruact").and include("Railtie")
        end
      end

      context "when the app opts in (layout = true)" do
        before { configure_layout(true) }

        it "puts the host app's stylesheet on a ruact page (the CSS could not arrive before)" do
          get "/layout-demo/show"

          expect(last_response.status).to(eq(200),
                                          "expected 200, got #{last_response.status} " \
                                          "body=#{last_response.body[0, 400]}")
          expect(last_response.body).to include('<link rel="stylesheet" href="/host-app.css" />')
        end

        # Story 17.0f (AC5) at integration level: the same app layout, one ruact
        # page and one plain Rails page.
        it "puts the Turbo meta on the ruact page and not on a plain page through the same layout",
           :aggregate_failures, :story_17_0f do
          meta = %(<meta name="turbo-visit-control" content="reload">)

          get "/layout-demo/show"
          expect(last_response.body).to include(meta)

          get "/plain-layout-demo/show"
          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("plain page")
          expect(last_response.body).not_to include(meta)
          expect(last_response.body).not_to include("turbo-prefetch")
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

        # Opting in and pointing ruact at a layout that cannot mount the app is
        # a configuration error, and silence would cost a blank page.
        it "fails loudly when the opted-in layout never calls ruact_js_assets" do
          expect { get "/unwired-layout-demo/show" }
            .to raise_error(Ruact::Error, /ruact_js_assets/)
        end

        it "fails loudly when the opted-in layout has no root div to mount into" do
          expect { get "/rootless-layout-demo/show" }
            .to raise_error(Ruact::Error, /root/)
        end

        # A controller that declares a layout which does not exist: Rails'
        # `_default_layout` returns the String path without checking it, so
        # "resolvable" has to mean "the template is actually there".
        it "degrades to the shell when a declared layout does not exist" do
          get "/ghost-layout-demo/show"

          expect(last_response.status).to(eq(200),
                                          "expected a degrade, got #{last_response.status} " \
                                          "body=#{last_response.body[0, 300]}")
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).to include("DemoButton")
        end

        # `layout false` on one controller inside an app that opted in globally
        # is a normal Rails pattern, not a mistake — it must degrade, not raise.
        it "degrades to the shell for a controller with no resolvable layout" do
          get "/demo/show"

          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("Rails RSC")
          expect(last_response.body).to include("DemoButton")
        end
      end

      context "when a named layout is configured" do
        before { configure_layout("ruact_host") }

        it "renders every ruact page through that layout" do
          get "/demo/show"

          expect(last_response.body).to include("host-app.css")
          expect(last_response.body).to include("DemoButton")
        end
      end
    end

    # Story 18-2 — content between a component's tags reaches it as children.
    describe "a component with children", :story_18_2 do
      it "passes the ERB between the tags as children: escaped output, a loop of components, a partial",
         :aggregate_failures do
        get "/children-demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200), last_response.body[0, 400]

        query = Ruact::Testing::ComponentQuery.new(last_response.body)
        card  = query.props_for("Card").first
        expect(card["title"]).to eq("Hi")
        # first(4): this app runs in development, whose wire adds React's dev slots.
        p_el, *buttons, span = card["children"]
        expect(p_el.first(4)).to eq(["$", "p", nil, { "children" => "<b>not markup</b>" }])
        expect(buttons.map { |b| b[3] }).to eq([{ "n" => 1 }, { "n" => 2 }])
        expect(span.first(4)).to eq(["$", "span", nil, { "children" => "from a partial" }])
        expect(query.props_for("DemoButton")).to eq([{ "n" => 1 }, { "n" => 2 }])
      end

      it "renders the page on a plain browser load" do
        get "/children-demo/show"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Card.jsx")
      end
    end

    describe "a page with Suspense boundaries" do
      def expect_suspense_page(body)
        expect(body).to include('"$Sreact.suspense"')
        expect(body).to include('"fallback":["$","p",null,{"children":"Loading …"}')
        expect(body).to include('"children":"<b>late</b>"')
        expect(Ruact::Testing::ComponentQuery.new(body).props_for("DemoButton")).to eq([{ "n" => 3 }])
        expect(body).not_to include("should not print")
      end

      it "evaluates each boundary's content in the view, and keeps only what it writes", :aggregate_failures do
        get "/suspense-demo/show", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200), last_response.body[0, 400]
        expect_suspense_page(last_response.body)
      end

      it "writes the same page row by row through ActionController::Live", :aggregate_failures do
        response = read_streamed("/suspense-live-demo/show", "HTTP_ACCEPT" => "text/x-component")
        expect(response.status).to eq(200), response.body[0, 400]
        expect(response.headers["X-Accel-Buffering"]).to eq("no")
        expect_suspense_page(response.body)
      end

      it "renders the page on a plain browser load" do
        get "/suspense-demo/show"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("__FLIGHT_DATA")
      end
    end

    # Story 19-1 — in an action that streams, each `<Suspense>`'s content runs
    # after the shell is sent. Rails' own test support would run Live inline;
    # this app is driven through Rack, so the action runs in Live's thread and
    # "after the shell is sent" is observable: the block sees a committed
    # response. That the browser SHOWS the fallback first is proved against a
    # server started on its own (spec/browser/deferred_suspense).
    describe "ruact_streaming (Story 19-1)" do
      let(:events) { ControllerRequestSpecSupport.events }
      let(:controller_class) { ControllerRequestSpecSupport::StreamingDemoController }

      before do
        events.clear
        I18n.backend.store_translations(
          :en, controller_request_spec_support: { streaming_demo: { show: { lazy: "Lazy text" },
                                                                    item: { label: "Item" } } }
        )
      end

      def flight(path, headers = {})
        read_streamed(path, { "HTTP_ACCEPT" => "text/x-component" }.merge(headers))
      end

      def document(path)
        read_streamed(path, { "HTTP_ACCEPT" => "text/html" })
      end

      def with_log
        io = StringIO.new
        previous = controller_class.logger
        controller_class.logger = Logger.new(io)
        yield
        io.string
      ensure
        controller_class.logger = previous
      end

      # A `<Suspense>` inside a block is met when that block runs, and queued
      # behind the ones the page already had.
      it "runs each block after the shell is sent, one at a time, in page order", :aggregate_failures do
        response = flight("/streaming-demo/show")
        expect(response.status).to eq(200)
        expect(events).to eq([[:shell, false], [:one, true], [:two, true], [:inner, true]])
        expect(response.headers["X-Accel-Buffering"]).to eq("no")
        # Story 19-2 — not stored: a stored response holds its cache entry while
        # it streams, and the browser holds a second request for the same URL.
        expect(response.headers["Cache-Control"]).to eq("no-store")
        body = response.body
        expect(body).to include('"fallback":["$","p",null,{"children":"Loading one"}')
        expect(body.index("Loading two")).to be < body.index("Lazy text")
        expect(body).to include("Lazy text")
        expect(body).to include("two \\u003cb\\u003eescaped\\u003c/b\\u003e").or include("two <b>escaped</b>")
        expect(Ruact::Testing::ComponentQuery.new(body).props_for("DemoButton")).to eq([{ "n" => 1 }])
      end

      it "renders a block with the template path it was written in (t('.key'))" do
        expect(flight("/streaming-demo/show").body).to include("Lazy text")
      end

      it "streams the first load: the document is sent, then each boundary's rows are pushed", :aggregate_failures do
        response = document("/streaming-demo/show")
        expect(response.status).to eq(200)
        expect(events).to eq([[:shell, false], [:one, true], [:two, true], [:inner, true]])
        expect(response.headers["Content-Type"]).to eq("text/html; charset=utf-8")
        # The document stays out of no-store: it would leave the back/forward cache.
        expect(response.headers["Cache-Control"]).to eq("no-cache")
        body = response.body
        pushes = body.scan("<script>(self.__FLIGHT_DATA=self.__FLIGHT_DATA||[]).push(")
        expect(pushes.length).to eq(3)
        expect(body.index("Lazy text")).to be < body.rindex("</body>")
        expect(body.index("Lazy text")).to be > body.index("__FLIGHT_DATA")
        expect(body).not_to match(%r{</script(?!>)}i)
      end

      # Story 19-2 — what tells the client router this document has rows to
      # come (it stops only such a document when it leaves the page): set
      # before the first boundary's rows, cleared after the last.
      it "marks the streamed document as streaming from the shell to the last boundary", :aggregate_failures do
        body = document("/streaming-demo/show").body
        open = body.index(".streaming=true</script>")
        done = body.index(".streaming=false</script>")
        push = "(self.__FLIGHT_DATA=self.__FLIGHT_DATA||[]).push("
        pushes = body.enum_for(:scan, push).map { Regexp.last_match.begin(0) }
        expect(open).to be < pushes.first
        expect(done).to be > pushes.last
        expect(done).to be < body.rindex("</body>")
        expect(document("/streaming-demo/plain").body).not_to include(".streaming=")
      end

      # The rows of a <Suspense> arrive in a script of their own: the matcher an
      # app's request spec uses has to read them too.
      it "lets have_ruact_component find a component that arrived with a boundary's rows" do
        expect(document("/streaming-demo/show").body).to have_ruact_component("DemoButton").with_props("n" => 1)
      end

      it "leaves an action it does not declare as it was: in place, buffered, with an ETag, on the request's thread",
         :aggregate_failures do
        response = flight("/streaming-demo/edit")
        expect(response.status).to eq(200)
        expect(events).to eq([[:thread, Thread.current],
                              [:shell, false], [:one, false], [:inner, false], [:two, false]])
        etag = response.headers["ETag"]
        expect(etag).not_to be_nil
        expect(flight("/streaming-demo/edit", "HTTP_IF_NONE_MATCH" => etag).status).to eq(304)
      end

      it "leaves an action it does not declare as it was when its endpoint is Controller.action(:name)",
         :aggregate_failures do
        response = flight("/streaming-direct-edit")
        expect(response.status).to eq(200)
        expect(response.headers["ETag"]).not_to be_nil
        expect(events.first).to eq([:thread, Thread.current])
      end

      it "streams an endpoint built with Controller.action(:name), whose route names no action",
         :aggregate_failures do
        response = flight("/streaming-direct")
        expect(response.status).to eq(200)
        expect(response.headers["X-Accel-Buffering"]).to eq("no")
        expect(events).to eq([[:shell, false], [:one, true], [:two, true], [:inner, true]])
      end

      # Story 19-2 (AC19.3) — on Rack 2, Rack::ETag reads a 200 body whole to
      # digest it unless the response has an ETag: a streamed one gets its own,
      # new each time, so no If-None-Match matches it. Not on Rack 3.
      it "gives a streamed response an ETag of its own on Rack 2, and none on Rack 3", :aggregate_failures do
        stub_const("Ruact::Controller::Streaming::RACK_ETAG_BUFFERS", true)
        first = flight("/streaming-demo/show").headers["ETag"]
        second = document("/streaming-demo/show").headers["ETag"]
        expect(first).to match(%r{\AW/"ruact-stream-\h{16}"\z})
        expect(second).to match(%r{\AW/"ruact-stream-\h{16}"\z})
        expect(first).not_to eq(second)

        stub_const("Ruact::Controller::Streaming::RACK_ETAG_BUFFERS", false)
        expect(flight("/streaming-demo/show").headers["ETag"]).to be_nil
      end

      # Review 19-2b R1 — an action's own validator (`fresh_when`) already keeps
      # Rack::ETag away, and conditional GET needs it: it is left as it is.
      it "leaves an ETag or a Last-Modified the action set", :aggregate_failures do
        stub_const("Ruact::Controller::Streaming::RACK_ETAG_BUFFERS", true)
        own = { "ETag" => 'W/"the-app"' }
        Ruact::Controller::Streaming.keep_unbuffered(own)
        expect(own).to eq("ETag" => 'W/"the-app"')
        dated = { "Last-Modified" => "Wed, 14 Oct 2026 10:00:00 GMT" }
        Ruact::Controller::Streaming.keep_unbuffered(dated)
        expect(dated.keys).to eq(["Last-Modified"])
      end

      # Story 19-2 (AC21) — an app whose CSP allows scripts by nonce: every
      # script ruact writes carries the request's nonce, the rows of each
      # boundary included; without a generator, not a byte changes.
      it "puts the request's CSP nonce on every script it writes, and none without one", :aggregate_failures do
        # The app's config is read once, at its first request: the request is stubbed instead.
        allow_any_instance_of(ActionDispatch::Request) # rubocop:disable RSpec/AnyInstance
          .to receive(:content_security_policy_nonce_generator).and_return(->(_request) { "n0nce" })
        body = document("/streaming-demo/show").body
        scripts = body.scan(/<script\b[^>]*>/)
        expect(scripts.length).to be >= 6
        expect(scripts).to all(include(' nonce="n0nce"'))
        expect(body).to include('<script nonce="n0nce">(self.__FLIGHT_DATA=self.__FLIGHT_DATA||[]).push(')

        allow_any_instance_of(ActionDispatch::Request) # rubocop:disable RSpec/AnyInstance
          .to receive(:content_security_policy_nonce_generator).and_return(nil)
        plain = document("/streaming-demo/show").body
        expect(plain).not_to include("nonce=")
        expect(plain.scan(/<script\b[^>]*>/).length).to eq(scripts.length)
      end

      # Story 19-2 (AC20) — that page was not streamed, and nothing said so: a
      # warning, once per process, naming the action and the proxy's line.
      it "says once that an action declared to stream got a request over HTTP/1.0", :aggregate_failures do
        Ruact::Controller::Streaming.reset_unstreamed_note!
        log = with_log do
          get "/streaming-demo/show"
          get "/streaming-demo/show"
        end
        line = "[ruact] ControllerRequestSpecSupport::StreamingDemoController#show streams (ruact_streaming"
        expect(log.scan(line).length).to eq(1)
        expect(log).to include("proxy_http_version 1.1;")
        expect(log).to match(/WARN/)

        # Over HTTP/1.1 it streams; an action not declared is not concerned.
        Ruact::Controller::Streaming.reset_unstreamed_note!
        expect(with_log { read_streamed("/streaming-demo/show") }).not_to include("an ordinary response")
        expect(with_log { get "/streaming-demo/edit" }).not_to include("an ordinary response")
      end

      # Review R3 — HTTP/1.0 (nginx's default to its upstream, Rack::Test): Live
      # answers with an ordinary response, so the page renders whole, in place,
      # with its blocks' content, and no development note asks to declare what
      # is declared.
      it "renders the whole page in place over HTTP/1.0", :aggregate_failures do
        allow(Rails.env).to receive(:development?).and_return(true)
        log = with_log { get "/streaming-demo/quiet", {}, { "HTTP_ACCEPT" => "text/x-component" } }
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("a slow block that writes nothing")
        expect(last_response.body).not_to include("ruact:suspense-error")
        expect(log).not_to include("does not stream")
        get "/streaming-demo/show"
        expect(events.map(&:last).uniq).to eq([false])
        expect(last_response.body).to include("Lazy text")
      end

      it "answers a page that left nothing for later as one that does not stream", :aggregate_failures do
        expect(flight("/streaming-demo/plain").body).to include("nothing deferred")
        expect(document("/streaming-demo/plain").body)
          .not_to include("(self.__FLIGHT_DATA=self.__FLIGHT_DATA||[]).push(")
      end

      it "turns a block that raises into an error row, reports it, and renders the next", :aggregate_failures do
        allow(Rails.error).to receive(:report).and_call_original
        allow(Rails.env).to receive(:development?).and_return(false)
        response = nil
        log = with_log { response = flight("/streaming-demo/raising") }
        body = response.body
        expect(response.status).to eq(200)
        expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-error"/)
        expect(body).to include("An error occurred in a <Suspense>")
        expect(body).not_to include("boom in a block")
        expect(body).to include("after the failure")
        expect(Rails.error).to have_received(:report)
          .with(an_instance_of(ArgumentError), hash_including(handled: true, source: "ruact.suspense"))
        expect(log).to include("<Suspense> content at ").and include("raising.html.erb").and include("boom in a block")
      end

      context "with a short suspense_timeout" do
        before do
          Ruact.configure do |c|
            c.manifest_path    = ControllerRequestSpecSupport.manifest_path
            c.suspense_timeout = 0.3
          end
        end

        it "ends a block that runs past it, even one that rescues StandardError", :aggregate_failures do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          body = flight("/streaming-demo/slow").body
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-timeout"/)
          expect(body).not_to include("never")
          expect(body).to include("after the timeout")
          expect(elapsed).to be < 2
        end

        it "ends a delay longer than it at once, with the timeout row", :aggregate_failures do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          body = flight("/streaming-demo/delayed").body
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.25
          expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-timeout"/)
        end
      end

      it "does not wait without a delay" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        flight("/streaming-demo/show")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      end

      # Story 19-3 — the page's JavaScript built by another ruact: in
      # development the document says so, and the log once.
      context "when the page's JavaScript was built by another ruact", :story_19_3 do
        let(:skewed) do
          entries = JSON.parse(File.read(ControllerRequestSpecSupport.manifest_path))
          Ruact::ClientManifest.from_hash({ "__ruact__" => { "version" => "0.0.1" } }.merge(entries))
        end

        before do
          Ruact::BuildSkew.reset!
          allow(Ruact::ManifestResolver).to receive(:resolve).and_return(skewed)
          allow_any_instance_of(Ruact::ViewHelper).to receive(:vite_dev_running?).and_return(true) # rubocop:disable RSpec/AnyInstance
        end

        after { Ruact::BuildSkew.reset! }

        it "says so on the page in development, and once in the log", :aggregate_failures do
          allow(Rails.env).to receive(:development?).and_return(true)
          bodies = []
          log = with_log { 2.times { bodies << document("/streaming-demo/plain").body } }
          expect(bodies).to all(include("data-ruact-build-skew")
            .and(include("built by ruact 0.0.1, and this server is ruact #{Ruact::VERSION}")))
          expect(log.scan("built by ruact 0.0.1").length).to eq(1)
          expect(flight("/streaming-demo/plain").body).not_to include("data-ruact-build-skew")
        end

        it "says nothing on the page in production" do
          allow(Rails.env).to receive(:development?).and_return(false)
          expect(document("/streaming-demo/plain").body).not_to include("data-ruact-build-skew")
        end
      end

      context "when the app runs in development" do
        before { allow(Rails.env).to receive(:development?).and_return(true) }

        it "makes a block that writes a cookie an error of that block, saying where it goes", :aggregate_failures do
          body = flight("/streaming-demo/late_write").body
          expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-error"/)
          expect(body).to include("the cookie theme")
          expect(body).to include("set in the controller, before the page renders")
          expect(body).not_to include("wrote</p>")
        end

        # The request's thread commits the session and the flash, and middleware
        # adds headers, once the shell is out — while the first block runs.
        # Those are Rails' writes, not the block's (review R1).
        it "does not take Rails' own writes after the shell for the block's" do
          5.times do
            # The document: its layout writes the session (the CSRF token).
            body = document("/streaming-demo/quiet").body
            expect(body).not_to include("ruact:suspense-error"), body
            expect(body).to include("a slow block that writes nothing")
          end
        end

        # Review R2 — an app that does not name its session cookie: the store's
        # own name is the one Rails writes.
        it "knows the session cookie by the store's name when the app gives none" do
          allow(Rails.application.config).to receive(:session_options).and_return({})
          5.times do
            body = document("/streaming-demo/quiet").body
            expect(body).not_to include("ruact:suspense-error"), body
          end
        end

        # Story 19-2 (AC7.2) — React's development client rebuilds the server's
        # stack from six-element frames; four left every frame at line 2.
        it "gives the error row frames React reads, with the template's file and line", :aggregate_failures do
          body = flight("/streaming-demo/positions").body
          row = body.lines.find { |line| line.include?("on line 8") }
          frames = JSON.parse(row.sub(/\A\h+:E/, ""))["stack"]
          expect(frames).to all(have_attributes(length: 6))
          template = frames.find { |frame| frame[1].end_with?("streaming_demo/positions.html.erb") }
          expect(template[2..]).to eq([8, 1, 0, 0])
        end

        # Story 19-2 (AC10.2) — the layout was sent before the block ran: what
        # it declares with content_for never shows. Reading it still works.
        it "makes content_for inside a block an error of that block, and lets it read", :aggregate_failures do
          body = flight("/streaming-demo/content_for").body
          expect(body).to include("set before")
          expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-error"/)
          expect(body).to include("content_for :sidebar")
          expect(body).not_to include("wrote content_for")
        end

        it "names the line to add when an action that does not stream renders a <Suspense>, once",
           :aggregate_failures do
          log = with_log { flight("/streaming-demo/edit") }
          expect(log.scan("does not stream").length).to eq(1)
          expect(log).to include("ControllerRequestSpecSupport::StreamingDemoController#edit renders a <Suspense>")
          expect(log).to include("streaming_demo/show.html.erb:4")
          expect(log).to include("ruact_streaming only: :edit")
        end
      end

      # Story 19-2 (AC6.2) — the page was sent whole; Live only logs an error
      # raised after the response started, so the app's error reporting would
      # never hear of it.
      it "reports an after_action that raises once the page was sent", :aggregate_failures do
        allow(Rails.error).to receive(:report).and_call_original
        response = document("/streaming-demo/after_raises")
        expect(response.status).to eq(200)
        expect(response.body).to include("a slow block that writes nothing")
        expect(response.body).not_to include("500.html")
        expect(Rails.error).to have_received(:report)
          .with(an_instance_of(ArgumentError), hash_including(source: "ruact.stream"))
      end

      # Story 19-2 (AC8.3) — a block runs after the rest of the template. Its
      # local variables are as they were when the tag was met — a local
      # reassigned below it, and `for`, which reuses one variable for every
      # item, showed the later value; an instance variable is read when the
      # block runs.
      it "gives a block its locals as they were at the tag, and instance variables as they are",
         :aggregate_failures do
        body = flight("/streaming-demo/capture").body
        seen = ->(kase) { body.scan(/"data-case":"#{kase}","children":"([^"]*)"/).flatten }
        expect(seen.call("local")).to eq(["1"])
        expect(seen.call("each")).to eq(%w[1 2 3])
        expect(seen.call("for")).to eq(%w[1 2 3])
        expect(seen.call("ivar")).to eq(["after"])
      end

      # Story 19-2 (AC10.1) — a block that renders nothing empties its boundary.
      it "renders a block that writes nothing as an empty boundary, and goes on", :aggregate_failures do
        body = flight("/streaming-demo/empty").body
        expect(body).not_to include(":E{")
        expect(body).not_to include("a value the block does not write")
        expect(body).to include("the last boundary")
        expect(body.lines.grep(/\A\h+:null\n\z/).length).to eq(4)
      end

      # Story 19-2 (AC8.4) — a <Suspense> in a partial, with its locals, in a
      # collection: each block sees its own item, and t(".key") the partial's scope.
      it "renders a <Suspense> in a partial and a collection with each one's own locals", :aggregate_failures do
        body = flight("/streaming-demo/partials").body
        expect(body.scan(/"data-item":"(\w+)","children":"Item (\w+)"/)).to eq(
          [%w[solo solo], %w[one one], %w[two two], %w[three three]]
        )
      end

      it "says nothing about an action that does not stream outside development" do
        allow(Rails.env).to receive(:development?).and_return(false)
        expect(with_log { flight("/streaming-demo/edit") }).not_to include("does not stream")
      end

      it "closes the stream when something fails once the response has started, without Rails' 500 script",
         :aggregate_failures do
        allow(Rails.error).to receive(:report).and_call_original
        allow_any_instance_of(controller_class).to receive(:__ruact_flight_push).and_raise(RuntimeError, "the tail") # rubocop:disable RSpec/AnyInstance
        response = nil
        log = with_log { response = document("/streaming-demo/show") }
        expect(response.status).to eq(200)
        expect(response.body).not_to include("500.html")
        expect(log).to include("raised while streaming").and include("the tail")
        expect(Rails.error).to have_received(:report)
          .with(an_instance_of(RuntimeError), hash_including(source: "ruact.stream"))
      end

      describe "the declaration" do
        def controller(&)
          Class.new(ActionController::Base) do
            include Ruact::Controller

            def self.name = "ControllerRequestSpecSupport::DeclarationDemoController"
            def show; end
            def feed; end
            class_eval(&)
          end
        end

        it "takes only: or except:, not both" do
          expect { controller { ruact_streaming only: :show, except: :feed } }
            .to raise_error(ArgumentError, /only: or except:, not both/)
        end

        it "fails loudly on a name that is not an action" do
          klass = controller { ruact_streaming only: %i[show shwo] }
          expect { klass.ruact_streaming?(:show) }
            .to raise_error(Ruact::ConfigurationError, /shwo, which is not an action/)
        end

        it "streams exactly the actions in only:, and is inherited", :aggregate_failures do
          klass = controller { ruact_streaming only: :show }
          expect(klass.ruact_streaming?(:show)).to be(true)
          expect(klass.ruact_streaming?(:feed)).to be(false)
          expect(Class.new(klass).ruact_streaming?(:show)).to be(true)
        end

        it "leaves out the actions in except: and the actions that are not pages", :aggregate_failures do
          klass = controller { ruact_streaming except: :feed }
          allow(klass).to receive(:ruact_page?).and_call_original
          allow(klass).to receive(:ruact_page?).with("show").and_return(true)
          expect(klass.ruact_streaming?(:show)).to be(true)
          expect(klass.ruact_streaming?(:feed)).to be(false)
          allow(klass).to receive(:ruact_page?).with("index").and_return(false)
          expect(klass.ruact_streaming?(:index)).to be(false)
        end

        it "streams every page of a controller that includes ActionController::Live and declares nothing" do
          klass = Class.new(ActionController::Base) do
            include ActionController::Live
            include Ruact::Controller
          end
          expect(klass.ruact_streaming?(:anything)).to be(true)
        end

        # Review R1 — the app's own Live actions (an SSE stream) keep Live when
        # ruact streams some pages of the same controller, or of a parent.
        it "keeps Live for the app's own actions under a parent that declared ruact_streaming",
           :aggregate_failures do
          parent = controller { ruact_streaming }
          events = Class.new(parent) do
            include ActionController::Live

            def stream; end
          end
          expect(events.ruact_streaming?(:stream)).to be(false)
          expect(events.__ruact_live?(:stream)).to be(true)
          expect(Class.new(parent).__ruact_live?(:stream)).to be(false)
        end

        it "keeps Live for every action of a controller that included it and declares only: some",
           :aggregate_failures do
          klass = Class.new(ActionController::Base) do
            include ActionController::Live
            include Ruact::Controller

            ruact_streaming only: :show
            def show; end
            def feed; end
          end
          expect(klass.ruact_streaming?(:feed)).to be(false)
          expect(klass.__ruact_live?(:feed)).to be(true)
          expect(controller { ruact_streaming only: :show }.__ruact_live?(:feed)).to be(false)
        end

        it "streams nothing for a controller with neither" do
          expect(Class.new(ActionController::Base) { include Ruact::Controller }.ruact_streaming?(:show)).to be(false)
        end
      end

      describe "connections the action's thread took" do
        before do
          require "active_record"
          ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        end

        it "are back in the pool when a streamed action ends" do
          pool = ::ActiveRecord::Base.connection_pool
          3.times { expect(flight("/streaming-demo/leased").status).to eq(200) }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          sleep 0.02 while pool.stat[:busy].positive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          expect(pool.stat[:busy]).to eq(0)
        end
      end
    end

    # Story 19-2 (AC9) — a `cache` block stores HTML with the markers of the
    # render that wrote it. Read back in another render, a marker used to pass
    # for one of that render's: another component, another boundary's block.
    describe "fragment caching (Story 19-2, AC9)" do
      before { ControllerRequestSpecSupport::CachingDemoController.cache_store.clear }

      def flight_body(path)
        read_streamed(path, "HTTP_ACCEPT" => "text/x-component").body
      end

      it "says nothing of a page that does not stream when nothing came out of a cache" do
        allow(Rails.error).to receive(:report).and_call_original
        get "/caching-demo/suspense_in_place", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(Rails.error).not_to have_received(:report)
      end

      it "fails loudly on a client component read from the cache, naming the cache" do
        get "/caching-demo/components", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect { get "/caching-demo/components", {}, { "HTTP_ACCEPT" => "text/x-component" } }
          .to raise_error(Ruact::HtmlConverterError, /came out of a `cache` block/)
      end

      it "gives a <Suspense> read from the cache an error row, never another boundary's content",
         :aggregate_failures do
        flight_body("/caching-demo/suspense?visit=1")
        body = flight_body("/caching-demo/suspense?visit=2")
        expect(body).to match(/^\h+:E\{"digest":"ruact:suspense-error"/)
        expect(body).to include("inside `cache`")
        expect(body.scan("second boundary").length).to eq(1)
      end

      it "gives an error row too when a page that does not stream reads what one that streams cached",
         :aggregate_failures do
        flight_body("/caching-demo/suspense?visit=1")
        get "/caching-demo/suspense_in_place", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("inside `cache`")
        expect(last_response.body.scan("second boundary").length).to eq(1)
      end

      # Review 19-2a R2 — the server says so too, as it does when it streams.
      it "reports a <Suspense> read from the cache by a page that does not stream" do
        flight_body("/caching-demo/suspense?visit=1")
        allow(Rails.error).to receive(:report).and_call_original
        get "/caching-demo/suspense_in_place", {}, { "HTTP_ACCEPT" => "text/x-component" }
        expect(Rails.error).to have_received(:report)
          .with(an_object_having_attributes(message: /inside `cache`/), hash_including(source: "ruact.suspense"))
      end

      it "shows the cached content when a page that streams reads what one that does not cached" do
        get "/caching-demo/suspense_in_place?visit=1", {}, { "HTTP_ACCEPT" => "text/x-component" }
        body = flight_body("/caching-demo/suspense?visit=2")
        expect(body).to include("first boundary, 1")
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

      # Story 17.0g review R3 — a plain 302 (a form outside `ruact_pages`, handed
      # to the browser) leaves the flash alone: the full page after it renders
      # a layout, and a layout that prints every flash entry would print the
      # errors Hash. That action is plain Rails; it re-renders the Rails way.
      it "does not stash errors on a plain 302", :aggregate_failures, :story_17_0g do
        post "/errors-demo/create", {}, { "HTTP_ACCEPT" => "text/html" }
        expect(last_response.status).to eq(302)

        get "/errors-demo/new", {}, flight_headers
        expect(last_response.body).not_to include("Title can't be blank")
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

    # Story 17.0i — `render :new, status: :unprocessable_entity`, the first thing
    # a Rails developer writes for a failed save, answered 500 on a ruact page
    # ("__ruact_component__ called outside a ruact_render flow").
    describe "Story 17.0i: a ruact page answers with a status", :story_17_0i do
      # Accept only, like the rest of this file: with `Ruact-Request: 1` the
      # navigation boundary (17.0f) would answer these spec-file controllers
      # (defined outside Rails.root/app) native, before the action runs.
      let(:flight_headers) { { "HTTP_ACCEPT" => "text/x-component" } }
      let(:html_headers)   { { "HTTP_ACCEPT" => "text/html" } }

      shared_examples "a ruact page answering 422" do |path, label|
        it "#{path}: renders through ruact with 422 — as HTML", :aggregate_failures do
          post path, {}, html_headers

          expect(last_response.status).to eq(422)
          expect(last_response.headers["Content-Type"]).to include("text/html")
          expect(last_response.body).to include(label)
          expect(last_response.body).to include(%(id="root"))
        end

        it "#{path}: renders through ruact with 422 — as Flight", :aggregate_failures do
          post path, {}, flight_headers

          expect(last_response.status).to eq(422)
          expect(last_response.headers["Content-Type"]).to include("text/x-component")
          expect(last_response.body).to include(label)
        end
      end

      it_behaves_like "a ruact page answering 422", "/status-demo/create_action", "status-new"
      it_behaves_like "a ruact page answering 422", "/status-demo/create_string", "status-new"
      it_behaves_like "a ruact page answering 422", "/status-demo/create_hash", "status-new"
      it_behaves_like "a ruact page answering 422", "/status-demo/create_template", "status-new"
      it_behaves_like "a ruact page answering 422", "/status-demo/create_locals", "from-locals"

      # `format.html` in a `respond_to` matches the HTML request. A Flight
      # request matches no format at all (`text/x-component` is not a Rails
      # MIME type) — a gap older than this story, in deferred-work.
      it "renders through ruact from a respond_to's format.html", :aggregate_failures do
        post "/status-demo/create_respond_to", {}, html_headers

        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new")
      end

      it_behaves_like "a ruact page answering 422", "/status-demo/explicit", "status-new"

      # Story 17-0j — `text/x-component` is not a Rails MIME type, so a router
      # request matched no `format` and `respond_to` raised UnknownFormat (406)
      # on every navigation and form submit of a scaffold-style controller.
      describe "respond_to on a router request (Story 17-0j)" do
        it "runs format.html for a navigation and answers Flight", :aggregate_failures do
          get "/status-demo/show_respond_to", {}, flight_headers

          expect(last_response.status).to eq(200)
          expect(last_response.headers["Content-Type"]).to include("text/x-component")
          expect(last_response.body).to include("respond-to-page")
        end

        it "runs format.html for a form submit, with the status it renders", :aggregate_failures do
          post "/status-demo/create_scaffold_style", {}, flight_headers

          expect(last_response.status).to eq(422)
          expect(last_response.headers["Content-Type"]).to include("text/x-component")
          expect(last_response.body).to include("status-new")
        end

        it "follows format.html's redirect with a Flight redirect row", :aggregate_failures do
          post "/status-demo/create_redirect_respond_to", {}, flight_headers

          expect(last_response.headers["Content-Type"]).to include("text/x-component")
          expect(last_response.body).to include('"redirectUrl":"/status-demo/new"')
        end

        it "still answers JSON to a .json URL", :aggregate_failures do
          get "/status-demo/show_respond_to.json", {}, flight_headers

          expect(last_response.status).to eq(200)
          expect(JSON.parse(last_response.body)).to eq("page" => "json")
        end

        it "still answers JSON to Accept: application/json" do
          get "/status-demo/show_respond_to", {}, { "HTTP_ACCEPT" => "application/json" }

          expect(JSON.parse(last_response.body)).to eq("page" => "json")
        end

        it "gives the format to a host callback prepended after the concern" do
          get "/auth-demo/show", {}, flight_headers

          expect(last_response.body).to include('"redirectUrl":"/status-demo/new"')
        end

        it "keeps the app's own UnknownFormat raised inside a format.html branch" do
          expect { get "/status-demo/show_inner_unknown", {}, flight_headers }
            .to raise_error(ActionController::UnknownFormat, "inner")
        end

        it "answers 406 when there is no format.html, and says why", :aggregate_failures do
          expect { get "/status-demo/show_json_only", {}, flight_headers }
            .to raise_error(ActionController::UnknownFormat, /format\.html/)
        end
      end

      it "streams a Flight 422 with ActionController::Live", :aggregate_failures do
        post "/status-live-demo/create", {}, flight_headers

        expect(last_response.status).to eq(422)
        expect(last_response.headers["Content-Type"]).to include("text/x-component")
        expect(last_response.body).to include("status-new")
      end

      it_behaves_like "a ruact page answering 422", "/status-demo/create_delegated", "status-new"

      it "keeps redirect_to callable with an explicit receiver, as Rails does", :aggregate_failures do
        post "/status-demo/redirect_delegated", {}, flight_headers

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("redirectUrl")
      end

      # Review R1 — what Rails negotiated wins: a `.json` path, `format.json`,
      # a jQuery-style XHR or an empty Accept all render what Rails picks.
      context "when Rails negotiated a format other than the page's" do
        it "renders the JSON template for a .json request with Accept */*", :aggregate_failures do
          post "/status-demo/create_scaffold_style.json", {}, { "HTTP_ACCEPT" => "*/*" }

          expect(last_response.status).to eq(201)
          expect(last_response.headers["Content-Type"]).to include("application/json")
          expect(last_response.body).to eq(%({"json":"show"}))
          expect(last_response.headers["Location"]).to end_with("/status-demo/1")
        end

        it "renders JSON for an XHR that prefers it" do
          post "/status-demo/create_scaffold_style", {},
               { "HTTP_ACCEPT" => "application/json, text/javascript, */*; q=0.01",
                 "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }

          expect(last_response.body).to eq(%({"json":"show"}))
        end

        it "renders the ruact page for an empty Accept, as Rails renders HTML", :aggregate_failures do
          post "/status-demo/create_action", {}, { "HTTP_ACCEPT" => "" }

          expect(last_response.status).to eq(422)
          expect(last_response.body).to include("status-new")
        end
      end

      it "takes formats: as a single value, as Rails does", :aggregate_failures do
        post "/status-demo/create_formats_html", {}, flight_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new")

        post "/status-demo/create_formats_json", {}, html_headers
        expect(last_response.status).to eq(201)
        expect(last_response.body).to eq(%({"json":"show"}))

        post "/status-demo/create_formats_nil", {}, html_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new")
      end

      # Review R2 — `Controller.render` (Turbo broadcasts use it) runs no action:
      # including the concern would not route it through ruact either.
      it "does not tell an off-request render to include the concern" do
        expect do
          ControllerRequestSpecSupport::StatusPlainDemoController.render(
            template: "controller_request_spec_support/implicit_demo/show"
          )
        end.to raise_error(ActionView::Template::Error, /only in a page a ruact controller renders/)
      end

      it "leaves a render with an option it does not know to Rails, and says which option" do
        expect { post "/status-demo/create_pdf", {}, html_headers }
          .to raise_error(ActionView::Template::Error, /`pdf:`.*not.*render option ruact takes/m)
      end

      it "names a stray option Rails would have ignored, instead of pointing at ruact_pages", :aggregate_failures do
        message = begin
          post "/status-demo/create_alert", {}, html_headers
          nil
        rescue ActionView::Template::Error => e
          e.message
        end

        expect(message).to include("`alert:`")
        expect(message).not_to include("ruact_pages")
      end

      it "leaves a render with prefixes: to Rails — it names another folder" do
        expect { post "/status-demo/create_prefixes", {}, html_headers }
          .to raise_error(ActionView::Template::Error, /implicit_demo/)
      end

      it "does not carry a declined render's explanation into a later render", :aggregate_failures do
        message = begin
          post "/status-rescue-demo/create", {}, html_headers
          nil
        rescue ActionView::Template::Error => e
          e.message
        end

        expect(message).to include("implicit_demo/show")
        expect(message).not_to include("`alert:`")
      end

      it "honours variant:, locale: and assigns: as Rails does", :aggregate_failures do
        post "/status-demo/create_variant", {}, html_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new-phone")

        post "/status-demo/create_locale", {}, flight_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new")

        post "/status-demo/create_assigns", {}, flight_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("from-assigns")
      end

      it "keeps the Location header a render asks for" do
        post "/status-demo/create_with_location", {}, html_headers

        expect(last_response.headers["Location"]).to end_with("/status-demo/1")
      end

      # Story 17.0h — a form on a TURBO page that posts to a ruact action: Turbo
      # fetches it, gets a ruact document carrying `turbo-visit-control=reload`
      # and reloads the page it is on — the validation errors and what was typed
      # are gone. In development ruact says so, naming the fix.
      context "when a Turbo form submission gets a ruact page back" do
        let(:log) { StringIO.new }

        before do
          allow_any_instance_of(ControllerRequestSpecSupport::StatusDemoController) # rubocop:disable RSpec/AnyInstance
            .to receive(:logger).and_return(Logger.new(log))
        end

        it "warns, naming the action, the form's request and data-turbo=\"false\"", :aggregate_failures do
          post "/status-demo/create_action", {}, html_headers.merge("HTTP_X_TURBO_REQUEST_ID" => "abc")

          expect(last_response.status).to eq(422)
          expect(log.string).to include("[ruact]")
            .and include("StatusDemoController#create_action")
            .and include("POST /status-demo/create_action")
            .and include(%(data-turbo="false"))
        end

        it "stays silent for the same request without Turbo, and for a Turbo GET", :aggregate_failures do
          post "/status-demo/create_action", {}, html_headers
          get "/status-demo/new", {}, html_headers.merge("HTTP_X_TURBO_REQUEST_ID" => "abc")

          expect(log.string).not_to include("data-turbo")
        end
      end

      it "keeps the status Rails would give when none is asked for" do
        post "/status-demo/create_no_status", {}, flight_headers

        expect(last_response.status).to eq(200)
      end

      it "leaves every other renderer to Rails", :aggregate_failures do
        post "/status-demo/create_json", {}, flight_headers
        expect(last_response.status).to eq(422)
        expect(JSON.parse(last_response.body)).to eq("ok" => false)

        post "/status-demo/create_plain", {}, flight_headers
        expect(last_response.status).to eq(422)
        expect(last_response.body).to eq("nope")
      end

      # A server-function call asks for JSON only: an HTML template is not its
      # answer, and ruact does not make it one.
      it "leaves a JSON-only request to Rails", :aggregate_failures do
        expect { post "/status-demo/create_action", {}, { "HTTP_ACCEPT" => "application/json" } }
          .to raise_error(ActionView::MissingTemplate)

        # `show` has a page AND a JSON template: Rails picks the JSON one.
        post "/status-demo/create_scaffold_style", {}, { "HTTP_ACCEPT" => "application/json" }
        expect(last_response.body).to eq(%({"json":"show"}))
      end

      it "ignores a layout: option — a ruact page renders into config.layout", :aggregate_failures do
        post "/status-demo/create_with_layout", {}, html_headers

        expect(last_response.status).to eq(422)
        expect(last_response.body).to include("status-new")
      end

      it "tells a controller without the concern to include it", :aggregate_failures do
        expect { post "/status-plain-demo/create", {}, html_headers }
          .to raise_error(ActionView::Template::Error) { |error|
                expect(error.message).to include("include Ruact::Controller")
                expect(error.message).not_to include("ruact_render(")
                expect(error.line_number).to eq("2")
              }
      end

      # AC3 — what Rails renders on its own fails naming the call that works.
      it "names ruact_render when Rails renders a template of another folder" do
        expect { post "/status-demo/create_other_folder", {}, flight_headers }
          .to raise_error(ActionView::Template::Error,
                          Regexp.new('<DemoButton />.*"controller_request_spec_support/implicit_demo/show".*' \
                                     'ruact_render\\(template: "controller_request_spec_support/implicit_demo/show"',
                                     Regexp::MULTILINE))
      end

      # AC4 — every document branch keeps the status.
      context "when the document renders through a layout" do
        def configure_layout(value)
          Ruact.configure do |c|
            c.manifest_path = ControllerRequestSpecSupport.manifest_path
            c.layout = value
          end
        end

        before { configure_layout(true) }

        it "keeps the status through the app's layout" do
          post "/layout-demo/create_unprocessable", {}, html_headers

          expect(last_response.status).to eq(422)
        end

        it "keeps the status when a declared layout does not exist (degraded to the shell)" do
          post "/ghost-layout-demo/create_unprocessable", {}, html_headers

          expect(last_response.status).to eq(422)
        end

        it "keeps the status when the layout cannot mount the app (production degrades)" do
          allow_any_instance_of(ControllerRequestSpecSupport::UnwiredLayoutDemoController) # rubocop:disable RSpec/AnyInstance
            .to receive(:__ruact_local_env?).and_return(false)
          post "/unwired-layout-demo/create_unprocessable", {}, html_headers

          expect(last_response.status).to eq(422)
        end
      end

      it "names ruact_pages when the template is not a declared page" do
        expect { post "/status-pages-demo/create", {}, flight_headers }
          .to raise_error(ActionView::Template::Error, /ruact_pages/)
      end
    end
  end
end
