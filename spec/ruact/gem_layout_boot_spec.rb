# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Story 17.0b (AC5) — the gem's layout resolves in an app that BOOTS through the
# Railtie, in development and production.
#
# Why a subprocess: the rest of the suite runs on a Rails stub, and the one spec
# that builds a real Rails::Application (controller_request_spec) requires
# ruact/controller by hand and never loads the Railtie. The view path the gem
# layout depends on is added BY the Railtie, and the risk being guarded is the
# hook — the prepend variant of this failed silently from
# `on_load(:action_controller)` (spike 2026-09-10). Only an app that boots the
# real initializer chain can say where the path lands. One process per
# environment, because a process holds one Rails.application.
GEM_LAYOUT_BOOT_SCRIPT = <<~RUBY
  # A constant, not a local: a `class` body opens a new scope, and a local
  # named `root` there silently resolves to the class's own `root` instead.
  BOOT_ROOT = ARGV.fetch(0)
  ENV["RAILS_ENV"] = ARGV.fetch(1)
  ENV["SECRET_KEY_BASE"] ||= "x" * 64

  require "rails"
  require "action_controller/railtie"
  require "action_view/railtie"
  require "ruact"
  require "json"
  require "logger"

  class BootApp < Rails::Application
    config.root = BOOT_ROOT
    config.eager_load = Rails.env.production?
    config.logger = Logger.new(IO::NULL)
    config.active_support.deprecation = :silence
    config.secret_key_base = "x" * 64
    config.consider_all_requests_local = true
    config.action_dispatch.show_exceptions = :none
    config.hosts.clear if config.respond_to?(:hosts)
    routes.append { get "/page", to: "pages#show" }
  end

  Ruact.configure do |c|
    c.layout = "ruact"
    c.manifest_path = File.join(BOOT_ROOT, "public", "react-client-manifest.json")
    # Nothing listens here, so the Vite dev server always reads as down and
    # the production-build path (the one that links CSS) is exercised.
    c.vite_dev_server = "http://127.0.0.1:9"
  end

  BootApp.initialize!

  # A controller the app did NOT give a view path of its own — the gem's
  # path has to come from the Railtie, not from the controller.
  module EngineSide
    class ThingsController < ActionController::Base; end
  end

  probe = ApplicationController.new.lookup_context
  status, headers, body = BootApp.call(Rack::MockRequest.env_for("/page", "HTTP_ACCEPT" => "text/html"))
  html = +""
  body.each { |part| html << part }

  puts JSON.generate(
    "view_paths" => ApplicationController.view_paths.map(&:to_s),
    "ruact_layout" => probe.find_all("ruact", ["layouts"]).first&.identifier,
    "application_layout" => probe.find_all("application", ["layouts"]).first&.identifier,
    "engine_side_sees_it" => EngineSide::ThingsController.new.lookup_context.exists?("ruact", ["layouts"]),
    "status" => status,
    "content_type" => headers["content-type"] || headers["Content-Type"],
    "html" => html
  )
RUBY

RSpec.describe "the gem's layout in a booted app (Story 17.0b)", :story_17_0b do
  let(:app_root) { Dir.mktmpdir("ruact_gem_layout_boot") }

  after { FileUtils.rm_rf(app_root) }

  def write(relative, body)
    path = File.join(app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  before do
    write("app/controllers/application_controller.rb", <<~RUBY)
      class ApplicationController < ActionController::Base
        include Ruact::Controller
      end
    RUBY
    write("app/controllers/pages_controller.rb",
          "class PagesController < ApplicationController\n  def show; end\nend\n")
    write("app/views/pages/show.html.erb", "<h1>booted</h1>\n")
    # The app's OWN layout, deliberately without any ruact wiring: Mode A
    # leaves it alone, and it must keep resolving as `layouts/application`.
    write("app/views/layouts/application.html.erb",
          "<html><head><title>APP LAYOUT</title></head><body><%= yield %></body></html>\n")
    write("public/react-client-manifest.json", "{}")
    write("public/assets/.vite/manifest.json", JSON.generate(
                                                 Ruact.bootstrap_virtual_id => {
                                                   "file" => "bootstrap-abc.js",
                                                   "css" => ["bootstrap-def.css"]
                                                 }
                                               ))
    write("script.rb", GEM_LAYOUT_BOOT_SCRIPT)
  end

  def boot(env)
    gem_lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", gem_lib, "-rbundler/setup",
                                      File.join(app_root, "script.rb"), app_root, env)
    raise "boot in #{env} failed (exit #{status.exitstatus}):\n#{err}\n#{out}" unless status.success?

    JSON.parse(out.lines.last)
  end

  # Why the order above can never shadow anything: the only view the gem ships is
  # `layouts/ruact`, a name that exists for ruact. A second file here — say a
  # `layouts/application.html.erb` — would compete with the app's by name, and
  # the prepend/append distinction would suddenly matter.
  it "ships exactly one view, layouts/ruact" do
    shipped = Dir.glob("**/*", base: Ruact.views_path).select { |path| File.file?(File.join(Ruact.views_path, path)) }

    expect(shipped).to eq(["layouts/ruact.html.erb"])
  end

  # Review round 1 — the view-path ORDER alone does not prove an ejected layout
  # wins (the order spec below stays green even with prepend). This does: an app
  # file with the gem layout's name, and the page rendered through it.
  context "when the app has its own layouts/ruact.html.erb (ejected)" do
    before do
      write("app/views/layouts/ruact.html.erb", <<~ERB)
        <!DOCTYPE html>
        <html><head><title>EJECTED</title><%= ruact_head_assets %></head>
        <body><div id="root"></div><%= ruact_js_assets %></body></html>
      ERB
    end

    it "renders through the app's copy, with no setting changed", :aggregate_failures do
      result = boot("development")

      expect(result["ruact_layout"]).to end_with("app/views/layouts/ruact.html.erb")
      expect(result["ruact_layout"]).not_to start_with(Ruact.views_path)
      expect(result["html"]).to include("<title>EJECTED</title>")
    end
  end

  %w[development production].each do |env|
    context "when booted in #{env}" do
      subject(:result) { boot(env) }

      # Measured while writing this spec: swapping the Railtie's append for a
      # prepend still lands the gem's path AFTER the app's here, because Rails
      # prepends the app's own views from the same hook, later. That is the
      # spike's "fails silently" finding seen from the other side — so the
      # invariant that actually protects the app is the next describe's: the gem
      # ships no view whose name an app could already own.
      it "puts the gem's views after the app's", :aggregate_failures do
        expect(result["view_paths"]).to include(Ruact.views_path)
        app_views = result["view_paths"].index do |path|
          path.end_with?("app/views") && !path.start_with?(Ruact.views_path)
        end
        expect(app_views).to be < result["view_paths"].index(Ruact.views_path)
      end

      it "resolves layouts/ruact to the gem's file, and layouts/application to the app's", :aggregate_failures do
        expect(result["ruact_layout"]).to eq(File.join(Ruact.views_path, "layouts/ruact.html.erb"))
        expect(result["application_layout"]).to end_with("app/views/layouts/application.html.erb")
        expect(result["application_layout"]).not_to start_with(Ruact.views_path)
      end

      it "is visible to a controller that never added a view path itself" do
        expect(result["engine_side_sees_it"]).to be(true)
      end

      it "renders a ruact page through it, with the component CSS in <head> before the app's", :aggregate_failures do
        expect(result["status"]).to eq(200)
        head = result["html"][%r{<head>.*?</head>}m]

        expect(head).to include(%(<link rel="stylesheet" href="/assets/bootstrap-def.css">))
        expect(head.index("bootstrap-def.css")).to be < head.index("app.css")
        expect(result["html"]).to include(%(<div id="root"></div>))
        expect(result["html"]).not_to include("APP LAYOUT")
        # Story 17.0f — the page is ruact's, so Turbo is told to reload rather
        # than swap it into a document of its own.
        expect(head).to include(%(<meta name="turbo-visit-control" content="reload">))
      end
    end
  end
end
