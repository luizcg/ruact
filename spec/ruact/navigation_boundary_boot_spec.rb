# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Story 17.0f (AC1, AC2) — the server decides, BEFORE any action runs, whether a
# request from the ruact router is headed for a ruact page.
#
# A subprocess, like gem_layout_boot_spec.rb: the middleware under test is
# installed by the Railtie, so only an app that boots through the Railtie shows
# whether it is in the stack, where, and what it sees. Every fixture comes from
# the 2026-09-16 spike (playgrounds/nav-islands), plus the case the spike never
# covered: a non-GET to a ruact controller with no template, which answers with a
# Flight redirect row and has to stay a ruact request.
#
# Each request records how many times its action ACTUALLY ran. "Not executed" is
# asserted on that counter, never inferred from the response.
GEM_BOUNDARY_BOOT_SCRIPT = <<~RUBY
  BOOT_ROOT = ARGV.fetch(0)
  ENV["RAILS_ENV"] = "test"

  require "rails"
  require "action_controller/railtie"
  require "action_view/railtie"
  require "ruact"
  require "json"
  require "logger"

  RUNS = Hash.new(0)

  module AdminPanel
    class Engine < ::Rails::Engine
      isolate_namespace AdminPanel
    end
  end

  class BoundaryApp < Rails::Application
    config.root = BOOT_ROOT
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.active_support.deprecation = :silence
    config.secret_key_base = "x" * 64
    config.consider_all_requests_local = true
    config.hosts.clear if config.respond_to?(:hosts)
    config.action_controller.allow_forgery_protection = false
    # Review round 1 (17.0f) — the documented way out must work from here,
    # before any initializer: the constant has to be loaded already.
    config.middleware.delete Ruact::NavigationBoundary::Middleware if ENV["BOUNDARY_REMOVED"]
  end

  Ruact.configure do |c|
    c.layout = "ruact"
    c.manifest_path = File.join(BOOT_ROOT, "public", "react-client-manifest.json")
    c.vite_dev_server = "http://127.0.0.1:9"
  end

  BoundaryApp.initialize!

  # Drawn AFTER boot: initialize! loads config/routes.rb (there is none here)
  # and would clear anything drawn before it.
  AdminPanel::Engine.routes.draw do
    get "reports", to: "dashboard#reports"
    get "session/new", to: "sessions#new"
    get "pages/:id", to: "pages#show"
    delete "pages/:id", to: "pages#destroy"
  end

  def call(method, path, headers: {}, params: nil)
    env = Rack::MockRequest.env_for(path, { method: method, params: params }.merge(headers))
    status, response_headers, body = BoundaryApp.call(env)
    body.close if body.respond_to?(:close)
    { "status" => status, "boundary" => response_headers["ruact-boundary"] || response_headers["Ruact-Boundary"] }
  end

  ROUTER = { "HTTP_RUACT_REQUEST" => "1", "HTTP_ACCEPT" => "text/x-component" }.freeze

  # The FIRST request is one that must come back native: the app's routes are
  # in config/routes.rb, and Rails 8 loads them lazily in development and test.
  # Classifying against a route table nobody loaded yet would pass it through.
  requests = {
    "rails page (GET)" => [:get, "/people/1", ROUTER],
    "ruact page (GET)" => [:get, "/products/1", ROUTER],
    "rails page, browser navigation" => [:get, "/people/1", { "HTTP_ACCEPT" => "text/html" }],
    "rails page, server-function JSON" => [:get, "/people/1", { "HTTP_ACCEPT" => "application/json" }],
    "constraint, odd -> rails" => [:get, "/item/1", ROUTER],
    "constraint, even -> ruact" => [:get, "/item/2", ROUTER],
    "redirect route" => [:get, "/go/people", ROUTER],
    "engine controller" => [:get, "/admin/reports", ROUTER],
    "devise-like engine controller" => [:get, "/admin/session/new", ROUTER],
    "mounted rack app" => [:get, "/rack", ROUTER],
    "no route" => [:get, "/nowhere", ROUTER],
    "POST to rails controller" => [:post, "/people", ROUTER],
    "POST to ruact controller without template" => [:post, "/products", ROUTER],
    "_method=delete to rails controller" => [:post, "/people/1", ROUTER, { "_method" => "delete" }],
    "_method=delete to ruact controller" => [:post, "/products/1", ROUTER, { "_method" => "delete" }],
    "ruact page inside an engine" => [:get, "/admin/pages/1", ROUTER],
    "DELETE to an engine controller inheriting the app's" => [:post, "/admin/pages/1", ROUTER, { "_method" => "delete" }],
    "redirect route to another origin" => [:get, "/elsewhere", ROUTER],
    "controller named ...ControllersController" => [:get, "/remote_controllers", ROUTER]
  }
  requests = requests.slice(*ENV["BOUNDARY_ONLY"].split("|")) if ENV["BOUNDARY_ONLY"]

  results = requests.to_h do |label, (method, path, headers, params)|
    RUNS.clear
    outcome = call(method, path, headers: headers, params: params)
    [label, outcome.merge("runs" => RUNS.values.sum)]
  end

  puts JSON.generate(results)
RUBY

RSpec.describe "the navigation boundary in a booted app (Story 17.0f)", :story_17_0f do
  def self.write(root, relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def self.build_app(root)
    write(root, "app/controllers/application_controller.rb", <<~RUBY)
      class ApplicationController < ActionController::Base
        include Ruact::Controller
      end
    RUBY
    write(root, "app/controllers/people_controller.rb", <<~RUBY)
      class PeopleController < ActionController::Base
        before_action { RUNS["people#\#{action_name}"] += 1 }
        def show = render(html: "<h1>person</h1>".html_safe)
        def create = render(html: "invalid".html_safe, status: :unprocessable_entity)
        def destroy = redirect_to("/people/1")
      end
    RUBY
    write(root, "app/controllers/products_controller.rb", <<~RUBY)
      class ProductsController < ApplicationController
        before_action { RUNS["products#\#{action_name}"] += 1 }
        def show; end
        def create = redirect_to("/products/1")
        def destroy = redirect_to("/products/1")
      end
    RUBY
    write(root, "app/views/products/show.html.erb", "<h1>product</h1>\n")
    # Review round 1 — the template path comes from controller_path; cutting
    # "_controller" out of the class name looked in remotes_controller/.
    write(root, "app/controllers/remote_controllers_controller.rb", <<~RUBY)
      class RemoteControllersController < ApplicationController
        before_action { RUNS["remote_controllers#\#{action_name}"] += 1 }
        def index; end
      end
    RUBY
    write(root, "app/views/remote_controllers/index.html.erb", "<h1>remotes</h1>\n")
    write(root, "app/controllers/admin_panel/dashboard_controller.rb", <<~RUBY)
      module AdminPanel
        class DashboardController < ActionController::Base
          before_action { RUNS["admin#\#{action_name}"] += 1 }
          def reports = render(html: "reports".html_safe)
        end
      end
    RUBY
    # Like Devise: inherits the APP's ruact controller, templates live elsewhere.
    write(root, "app/controllers/admin_panel/sessions_controller.rb", <<~RUBY)
      module AdminPanel
        class SessionsController < ::ApplicationController
          before_action { RUNS["sessions#\#{action_name}"] += 1 }
          def new = render(html: "login".html_safe)
        end
      end
    RUBY
    # An engine controller inheriting the app's, whose GET page has a template
    # in the APP (how apps override engine views): a ruact page reached only by
    # descending into the engine. Its DELETE speaks the engine's protocol.
    write(root, "app/controllers/admin_panel/pages_controller.rb", <<~RUBY)
      module AdminPanel
        class PagesController < ::ApplicationController
          before_action { RUNS["pages#\#{action_name}"] += 1 }
          def show; end
          def destroy = head(:no_content)
        end
      end
    RUBY
    write(root, "app/views/admin_panel/pages/show.html.erb", "<h1>engine page</h1>\n")
    # In config/routes.rb, NOT drawn by the script: Rails 8 loads these lazily
    # in development and test, which is the case the classifier must survive.
    write(root, "config/routes.rb", <<~RUBY)
      Rails.application.routes.draw do
        # A Rack app at "/" that passes on what it does not know (Grape and
        # Sinatra do this): Rails moves on to the routes below, and so must the
        # classifier.
        mount ->(_env) { [404, { "x-cascade" => "pass" }, []] }, at: "/" if ENV["BOUNDARY_ROOT_MOUNT"]
        resources :people, only: %i[show create destroy]
        resources :products, only: %i[show create destroy]
        get "item/:id", to: "people#show", constraints: ->(req) { req.path_parameters[:id].to_i.odd? }
        get "item/:id", to: "products#show"
        get "go/people", to: redirect("/people/1")
        get "elsewhere", to: redirect("https://blog.example.org/")
        get "remote_controllers", to: "remote_controllers#index"
        mount AdminPanel::Engine, at: "/admin"
        mount ->(_env) { RUNS["rack"] += 1; [200, { "content-type" => "text/html" }, ["rack"]] }, at: "/rack"
      end
    RUBY
    write(root, "public/react-client-manifest.json", "{}")
    write(root, "script.rb", GEM_BOUNDARY_BOOT_SCRIPT)
  end

  def self.boot(env = {})
    root = Dir.mktmpdir("ruact_boundary_boot")
    build_app(root)
    gem_lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", gem_lib, "-rbundler/setup",
                                      File.join(root, "script.rb"), root)
    raise "boundary boot failed (exit #{status.exitstatus}):\n#{err}\n#{out}" unless status.success?

    JSON.parse(out.lines.last)
  ensure
    FileUtils.rm_rf(root) if root
  end

  # rubocop:disable RSpec/InstanceVariable -- one subprocess boot for the whole group
  before(:context) { @results = self.class.boot } # rubocop:disable RSpec/BeforeAfterAll -- read-only results

  def outcome(label) = @results.fetch(label)
  # rubocop:enable RSpec/InstanceVariable

  shared_examples "answered native without running the action" do |label|
    it "#{label}: Ruact-Boundary: native, action never ran", :aggregate_failures do
      expect(outcome(label)["boundary"]).to eq("native")
      expect(outcome(label)["runs"]).to eq(0)
    end
  end

  shared_examples "passed through to the app" do |label|
    it "#{label}: no boundary header, the app answered" do
      expect(outcome(label)["boundary"]).to be_nil
    end
  end

  it_behaves_like "answered native without running the action", "rails page (GET)"
  it_behaves_like "answered native without running the action", "constraint, odd -> rails"
  it_behaves_like "answered native without running the action", "engine controller"
  it_behaves_like "answered native without running the action", "devise-like engine controller"
  it_behaves_like "answered native without running the action", "mounted rack app"
  it_behaves_like "answered native without running the action", "POST to rails controller"
  it_behaves_like "answered native without running the action", "_method=delete to rails controller"
  it_behaves_like "answered native without running the action", "DELETE to an engine controller inheriting the app's"
  it_behaves_like "answered native without running the action", "redirect route to another origin"

  it_behaves_like "passed through to the app", "ruact page (GET)"
  it_behaves_like "passed through to the app", "constraint, even -> ruact"
  it_behaves_like "passed through to the app", "redirect route"
  it_behaves_like "passed through to the app", "no route"
  it_behaves_like "passed through to the app", "ruact page inside an engine"
  it_behaves_like "passed through to the app", "controller named ...ControllersController"

  # The case the spike missed: no create.html.erb, but the gem's redirect_to
  # answers a ruact request with a Flight redirect row. Classifying it native
  # would turn the Story 13.3 redirect-back into a full page load.
  it_behaves_like "passed through to the app", "POST to ruact controller without template"
  it_behaves_like "passed through to the app", "_method=delete to ruact controller"

  it "runs the ruact actions it lets through exactly once", :aggregate_failures do
    expect(outcome("ruact page (GET)")["runs"]).to eq(1)
    expect(outcome("POST to ruact controller without template")["runs"]).to eq(1)
    expect(outcome("_method=delete to ruact controller")["runs"]).to eq(1)
    expect(outcome("ruact page inside an engine")["runs"]).to eq(1)
  end

  it "never touches a request the ruact router did not send", :aggregate_failures do
    expect(outcome("rails page, browser navigation")).to include("boundary" => nil, "runs" => 1)
    expect(outcome("rails page, server-function JSON")).to include("boundary" => nil, "runs" => 1)
  end

  context "when a Rack app mounted at / passes on what it does not know" do
    it "keeps classifying the routes below it", :aggregate_failures do
      results = self.class.boot("BOUNDARY_ROOT_MOUNT" => "1", "BOUNDARY_ONLY" => "ruact page (GET)|rails page (GET)")

      expect(results["ruact page (GET)"]).to include("boundary" => nil, "runs" => 1)
      expect(results["rails page (GET)"]).to include("boundary" => "native", "runs" => 0)
    end
  end

  context "when the app removes the middleware in config/application.rb" do
    it "boots, and the router's requests reach the app untouched" do
      results = self.class.boot("BOUNDARY_REMOVED" => "1", "BOUNDARY_ONLY" => "rails page (GET)")

      expect(results["rails page (GET)"]).to include("boundary" => nil, "runs" => 1)
    end
  end
end
