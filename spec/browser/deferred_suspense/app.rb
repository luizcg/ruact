# frozen_string_literal: true

# Story 19-1 — the app the browser proof runs against: the gem as it is, with
# no patch of its own. One file, the default middleware stack of
# `config.load_defaults 8.1`, Puma in front. Grown from the 19-0 experiment
# (docs/internal/spikes/deferred-suspense), which proved the design against a
# prototype.
#
#   RAILS_ENV=development|production
#   HARNESS_IN_PLACE=1    the perturbation: every <Suspense> renders in place,
#                         as in 0.0.19 — the proof must fail at what the browser shows
#   HARNESS_TIMEOUT=secs  Ruact.config.suspense_timeout (default 30: scenarios hold blocks at gates)

require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"
require "web-console" if ENV.fetch("RAILS_ENV", "development") == "development"
require "ruact"

require_relative "gate"

%w[tmp log results].each { |dir| FileUtils.mkdir_p(File.join(__dir__, dir)) }

ENV["DATABASE_URL"] ||= "sqlite3:#{File.join(__dir__, 'tmp', "harness-#{ENV.fetch('PORT', '0')}.sqlite3")}?pool=10"

module Harness
  # What happened on the server, in order, for the tests to read: what the
  # views record, what ruact logs, what Rails.error is told.
  module Events
    @mutex = Mutex.new
    @all = []

    def self.add(event)
      @mutex.synchronize { @all << event }
      nil
    end

    def self.all
      @mutex.synchronize { @all.dup }
    end

    def self.clear
      @mutex.synchronize { @all.clear }
    end
  end

  # Story 19-2 (AC5) — a failure once the response has started, outside any
  # block: armed by the test, it makes the second boundary's write raise.
  module FailStream
    @mutex = Mutex.new
    @armed = false
    @calls = 0

    def self.arm
      @mutex.synchronize do
        @armed = true
        @calls = 0
      end
    end

    def self.clear
      @mutex.synchronize do
        @armed = false
        @calls = 0
      end
    end

    def self.now?
      @mutex.synchronize do
        next false unless @armed

        @calls += 1
        @calls == 2
      end
    end
  end

  # Something that happens the first time only, until the next reset.
  module Once
    @mutex = Mutex.new
    @seen = []

    def self.first?(name)
      @mutex.synchronize do
        next false if @seen.include?(name)

        @seen << name
        true
      end
    end

    def self.clear
      @mutex.synchronize { @seen.clear }
    end
  end

  # The `[ruact]` lines of the log, as events.
  class RuactLog < ::Logger
    def initialize
      super(nil)
    end

    def add(_severity, message = nil, progname = nil) # rubocop:disable Naming/PredicateMethod -- Logger#add's contract
      text = message || (block_given? ? yield : progname)
      Events.add("log:#{text}") if text.to_s.include?("[ruact]")
      true
    end
  end
end

# A middleware that leaves on the thread what a middleware or a gem might, so a
# view can say which thread it runs on.
class ThreadMarker
  def initialize(app) = @app = app

  def call(env)
    env["harness.thread"] = Thread.current.object_id
    Thread.current[:harness_fiber_local] = "set"
    Thread.current.thread_variable_set(:harness_thread_variable, "set")
    @app.call(env)
  end
end

class HarnessApp < Rails::Application
  config.root = __dir__
  config.load_defaults 8.1
  config.secret_key_base = "harness-19-1"

  # What `rails new` (8.1) writes in config/environments/*.rb, where it decides
  # which middleware the app has.
  config.eager_load = Rails.env.production?
  config.enable_reloading = Rails.env.development?
  config.consider_all_requests_local = Rails.env.development?
  config.cache_store = :memory_store
  if Rails.env.development?
    config.server_timing = true
    config.assets.quiet = true
    config.active_record.migration_error = :page_load
  else
    config.assume_ssl = true
    config.force_ssl = true
    config.ssl_options = { hsts: false } # the browser runs it on http://localhost
    config.silence_healthcheck_path = "/up"
  end
  config.logger = ActiveSupport::BroadcastLogger.new(
    ActiveSupport::Logger.new(File.join(__dir__, "log", "#{Rails.env}.log")), Harness::RuactLog.new
  )
  config.log_level = :info
  config.i18n.available_locales = %i[en pt]
  config.i18n.default_locale = :en
  config.middleware.use ThreadMarker
end

Ruact.configure do |config|
  config.layout = "ruact"
  config.vite_dev_server = "http://localhost:#{ENV.fetch('VITE_PORT', '5199')}"
  # Scenarios synchronise on gates, not time: the timeout must not end a block
  # a scenario is still holding at a gate. HARNESS_TIMEOUT sets it for the ones
  # that measure it.
  config.suspense_timeout = Float(ENV.fetch("HARNESS_TIMEOUT", "30"))
end

# A query that waits at a gate: `SELECT … WHERE gate_wait('a') = 1` holds its
# connection until the gate opens, like a slow query would.
module GateFunction
  private

  def configure_connection
    super
    @raw_connection.create_function("gate_wait", 1) do |fn, name|
      fn.result = Gate.wait(name.to_s) ? 1 : 0
    end
  end
end

ActiveSupport.on_load(:active_record_sqlite3adapter) { prepend GateFunction }

Rails.application.initialize!

# What the app's error reporting (Sentry and the like) would be told.
Rails.error.subscribe(Class.new do
  def report(error, source: nil, **)
    Harness::Events.add("reported:#{error.class}:#{source}")
  end
end.new)

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:items, force: true) { |t| t.string :name }
end

# Story 19-2 (AC5): the failure the test arms, at the second boundary — after
# the shell was written, outside any block.
Ruact::DeferredRender.prepend(Module.new do
  def next_rows
    raise "the stream failed after the first write" if Harness::FailStream.now?

    super
  end
end)

# The perturbation: the helper renders every <Suspense> in place, as 0.0.19
# did, though the action still streams.
if ENV["HARNESS_IN_PLACE"] == "1"
  Ruact::RenderContext.prepend(Module.new do
    def deferring? = false
  end)
end

class Current < ActiveSupport::CurrentAttributes
  attribute :user
end

# What an `around_action` scopes: a tenant that exists only inside the block.
module Tenant
  def self.with(name)
    previous = ActiveSupport::IsolatedExecutionState[:harness_tenant]
    ActiveSupport::IsolatedExecutionState[:harness_tenant] = name
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:harness_tenant] = previous
  end

  def self.current
    ActiveSupport::IsolatedExecutionState[:harness_tenant] || "(none)"
  end
end

class Item < ActiveRecord::Base
end

Item.create!(name: "one")
Item.create!(name: "two")
ActiveRecord::Base.connection_pool.disconnect!

class ApplicationController < ActionController::Base
  include Ruact::Controller
end

class PagesController < ApplicationController
  # Every page streams but `plain`, which shows that an action left out keeps
  # the request's thread.
  ruact_streaming except: :plain

  around_action :scoped, only: :context
  # Story 19-2 (AC6) — an after_action that writes once the page was sent.
  after_action(only: :after_write) do
    cookies[:after] = "1"
    response.headers["X-After"] = "1"
    Harness::Events.add("after_write ran")
  end
  after_action(only: :context) { Harness::Events.add("after_action") }

  def home; end
  def plain; end
  def slow; end
  def two; end
  def nested; end
  def error; end
  def late_cookie; end
  def leased; end
  def flaky; end
  def errors; end
  def after_write; end

  def context
    Current.user = "ada"
  end

  # A slow query inside the block: a lazy relation, loaded where the view walks it.
  def db
    @items = Item.where("gate_wait('a') = 1")
  end

  private

  def scoped(&)
    I18n.with_locale(:pt) do
      Time.use_zone("Tokyo") do
        Tenant.with("acme", &)
      end
    end
  end
end

# The test's side door: open a gate, read what the server is doing.
class ProbeController < ActionController::API
  def open
    Gate.open(params[:name])
    head :no_content
  end

  def reset
    Gate.reset
    Harness::Events.clear
    Harness::Once.clear
    Harness::FailStream.clear
    head :no_content
  end

  def state
    render json: {
      env: Rails.env,
      waiting: Gate.waiting,
      events: Harness::Events.all,
      pool: ActiveRecord::Base.connection_pool.stat
    }
  end

  def session_probe
    render json: { early: request.session[:early], late: request.session[:late], cookies: request.cookies.keys.sort }
  end

  def up
    head :ok
  end

  def fail_stream
    Harness::FailStream.arm
    head :no_content
  end
end

Rails.application.routes.draw do
  root "pages#home"
  %w[plain slow two nested error context db late_cookie leased flaky errors after_write].each do |page|
    get page, to: "pages##{page}"
  end
  post "__gate/reset", to: "probe#reset"
  post "__gate/:name/open", to: "probe#open"
  get "__state", to: "probe#state"
  get "__session", to: "probe#session_probe"
  get "up", to: "probe#up"
  post "__fail_stream", to: "probe#fail_stream"
end
