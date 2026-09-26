# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "fileutils"
require "generators/ruact/install/install_generator"

# Story 17.0g (FR116) — installing ruact into an app that already has pages
# changes none of them.
#
# Measured in the 2026-09-14 correct course (E1): the install put
# `include Ruact::Controller` on ApplicationController, and `default_render`
# then took EVERY action with an `.html.erb` — a plain page with a Turbo Frame
# came back with the frame turned into a React element and its markup gone from
# the server HTML. This spec runs the REAL install over a small app, then boots
# that app through the Railtie and asks for the untouched page, before and
# after: the two responses have to be the same bytes.
ADOPTION_BOOT_SCRIPT = <<~RUBY
  BOOT_ROOT = ARGV.fetch(0)
  ENV["RAILS_ENV"] = "test"

  require "rails"
  require "action_controller/railtie"
  require "action_view/railtie"
  require "ruact"
  require "json"
  require "logger"

  class AdoptionApp < Rails::Application
    config.root = BOOT_ROOT
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.active_support.deprecation = :silence
    config.secret_key_base = "x" * 64
    config.consider_all_requests_local = true
    config.hosts.clear if config.respond_to?(:hosts)
  end

  initializer = File.join(BOOT_ROOT, "config/initializers/ruact.rb")
  load initializer if File.exist?(initializer)
  Ruact.configure { |c| c.manifest_path = File.join(BOOT_ROOT, "public/react-client-manifest.json") }

  AdoptionApp.initialize!

  status, _headers, body = AdoptionApp.call(Rack::MockRequest.env_for("/legacy", "HTTP_ACCEPT" => "text/html"))
  html = +""
  body.each { |part| html << part }
  puts JSON.generate("status" => status, "html" => html)
RUBY

RSpec.describe "installing ruact into an existing app (Story 17.0g)", :story_17_0g do
  let(:app_root) { Dir.mktmpdir("ruact_adoption") }

  after { FileUtils.rm_rf(app_root) }

  def write(relative, body)
    path = File.join(app_root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # Every command the install runs, minus the two that shell out.
  def run_install(opts = {})
    gen = Ruact::Generators::InstallGenerator.new([], { skip_npm: true }.merge(opts), destination_root: app_root)
    original = $stdout
    $stdout = StringIO.new
    (Ruact::Generators::InstallGenerator.all_commands.keys -
      %w[install_javascript_dependencies prime_server_functions_codegen]).each { |command| gen.public_send(command) }
  ensure
    $stdout = original
  end

  def boot_and_get_legacy
    gem_lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", gem_lib, "-rbundler/setup",
                                      File.join(app_root, "script.rb"), app_root)
    raise "boot failed (exit #{status.exitstatus}):\n#{err}\n#{out}" unless status.success?

    JSON.parse(out.lines.last)
  end

  before do
    write("app/controllers/application_controller.rb", "class ApplicationController < ActionController::Base\nend\n")
    write("app/controllers/legacy_controller.rb",
          "class LegacyController < ApplicationController\n  def index; end\nend\n")
    write("app/views/legacy/index.html.erb", <<~ERB)
      <h1>Tela antiga</h1>
      <turbo-frame id="comments"><p>frame</p></turbo-frame>
    ERB
    # No csrf_meta_tags: the token differs per request, and the point is to
    # compare two responses byte for byte.
    write("app/views/layouts/application.html.erb", "<!DOCTYPE html>\n<html><body><%= yield %></body></html>\n")
    write("config/routes.rb", %(Rails.application.routes.draw { get "legacy", to: "legacy#index" }\n))
    write("public/react-client-manifest.json", "{}")
    write(".gitignore", "/log/*\n")
    write("script.rb", ADOPTION_BOOT_SCRIPT)
  end

  it "leaves an existing page byte-identical — the Turbo Frame is still HTML", :aggregate_failures do
    before_install = boot_and_get_legacy
    run_install
    after_install = boot_and_get_legacy

    expect(after_install["status"]).to eq(200)
    expect(after_install["html"]).to include(%(<turbo-frame id="comments">))
    expect(after_install["html"]).to eq(before_install["html"])
  end

  it "does not touch ApplicationController" do
    run_install

    expect(File.read(File.join(app_root, "app/controllers/application_controller.rb")))
      .to eq("class ApplicationController < ActionController::Base\nend\n")
  end

  # `--app` is the explicit way to the old behaviour: the concern on
  # ApplicationController, the app's own layout.
  it "converts the app only under --app", :aggregate_failures do
    run_install(app: true)

    expect(File.read(File.join(app_root, "app/controllers/application_controller.rb"))).to include("include Ruact::Controller")
    expect(File.read(File.join(app_root, "config/initializers/ruact.rb"))).to match(/^\s*config\.layout = true$/)
  end
end
