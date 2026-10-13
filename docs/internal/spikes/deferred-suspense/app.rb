# frozen_string_literal: true

# Story 19-0 — the app the experiment runs. One file, the default middleware
# stack of `config.load_defaults 8.1`, Puma in front.
#
#   SPIKE_MODE=baseline  ruact as released, with ActionController::Live (today's best case)
#   SPIKE_MODE=live      the prototype, delivered through ActionController::Live
#   SPIKE_MODE=body      the prototype, delivered through a lazy Rack body (no Live)
#
#   SPIKE_SELECTIVE=1    (live) Live for every action but `plain`, chosen per request
#   SPIKE_PEEK=1         ask the socket whether the client is still there before each block
#   SPIKE_ASYNC=1        config.active_record.async_query_executor = :global_thread_pool
#   SPIKE_DEFLATER=1     adds Rack::Deflater
#   SPIKE_TIMEOUT=secs   Ruact.config.suspense_timeout

require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "propshaft"
require "web-console" if ENV.fetch("RAILS_ENV", "development") == "development"
require "ruact"

SPIKE_MODE = ENV.fetch("SPIKE_MODE", "baseline")
abort "SPIKE_MODE must be baseline, live or body" unless %w[baseline live body].include?(SPIKE_MODE)

require_relative "gate"

%w[tmp log results].each { |dir| FileUtils.mkdir_p(File.join(__dir__, dir)) }

ENV["DATABASE_URL"] ||= "sqlite3:#{File.join(__dir__, 'tmp', "spike-#{ENV.fetch('PORT', '0')}.sqlite3")}?pool=5"

# The one middleware of the experiment's own: it lets a view say which thread
# it runs on, and leaves on the thread what a middleware or a gem might.
class ThreadMarker
  def initialize(app) = @app = app

  def call(env)
    env["spike.thread"] = Thread.current.object_id
    Thread.current[:spike_fiber_local] = "set"
    Thread.current.thread_variable_set(:spike_thread_variable, "set")
    # A middleware that picks the locale for the request (rack-contrib's
    # Rack::Locale and others do this), for one path.
    return I18n.with_locale(:pt) { @app.call(env) } if env["PATH_INFO"] == "/mw"

    @app.call(env)
  end
end

class SpikeApp < Rails::Application
  config.root = __dir__
  config.load_defaults 8.1
  config.secret_key_base = "spike-19-0"

  # What `rails new` (8.1.4) writes in config/environments/*.rb, where it
  # decides which middleware the app has. measure/measure.rb compares the
  # resulting stack with the one a generated app reports.
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
  config.logger = ActiveSupport::Logger.new(File.join(__dir__, "log", "#{Rails.env}.log"))
  config.log_level = :info
  config.i18n.available_locales = %i[en pt]
  config.i18n.default_locale = :en
  config.active_record.async_query_executor = :global_thread_pool if ENV["SPIKE_ASYNC"] == "1"
  config.middleware.use Rack::Deflater if ENV["SPIKE_DEFLATER"] == "1"
  config.middleware.use ThreadMarker
end

Ruact.configure do |config|
  config.layout = "ruact"
  config.vite_dev_server = "http://localhost:#{ENV.fetch('VITE_PORT', '5173')}"
  config.suspense_timeout = Float(ENV["SPIKE_TIMEOUT"]) if ENV["SPIKE_TIMEOUT"]
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

module Spike
  # What happened on the server, in order, for the tests to read.
  module Events
    @mutex = Mutex.new
    @all = []

    def self.add(event)
      @mutex.synchronize { @all << event }
    end

    def self.all
      @mutex.synchronize { @all.dup }
    end

    def self.clear
      @mutex.synchronize { @all.clear }
    end
  end
end

Rails.application.initialize!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:items, force: true) { |t| t.string :name }
end

require_relative "prototype/deferred" unless SPIKE_MODE == "baseline"

class Current < ActiveSupport::CurrentAttributes
  attribute :user
end

# What an `around_action` scopes: a tenant that exists only inside the block.
module Tenant
  def self.with(name)
    previous = ActiveSupport::IsolatedExecutionState[:spike_tenant]
    ActiveSupport::IsolatedExecutionState[:spike_tenant] = name
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:spike_tenant] = previous
  end

  def self.current
    ActiveSupport::IsolatedExecutionState[:spike_tenant] || "(none)"
  end
end

class Item < ActiveRecord::Base
end

Item.create!(name: "one")
Item.create!(name: "two")
ActiveRecord::Base.connection_pool.disconnect!

class ApplicationController < ActionController::Base
  include Ruact::Controller

  if ENV["SPIKE_SELECTIVE"] == "1"
    require_relative "prototype/selective_live"
    include Spike::SelectiveLive
  elsif SPIKE_MODE != "body"
    include ActionController::Live
  end
  include Spike::Delivery unless SPIKE_MODE == "baseline"
end

class PagesController < ApplicationController
  around_action :scoped, only: :context
  after_action(only: :context) { Spike::Events.add("after_action") }
  # What an app's own after_action does to a response: a header, a cookie.
  after_action(only: %i[plain slow]) do
    Gate.wait("after") if params[:hold] # an after_action that takes any time at all
    response.headers["X-After-Action"] = "set"
    cookies[:after_action] = "1"
  end

  def home; end
  def plain; end
  def slow; end
  def two; end
  def nested; end
  def error; end
  def late_cookie; end
  def mw; end
  def same; end
  def timeout; end

  def context
    Current.user = "ada"
  end

  # A slow query inside the block: a lazy relation, loaded where the view walks it.
  def db
    @items = Item.where("gate_wait('a') = 1")
  end

  # Two queries started from the controller with `load_async`.
  def db_async
    @first  = Item.where("gate_wait('a') = 1").load_async
    @second = Item.where("gate_wait('b') = 1").load_async
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
    Spike::Events.clear
    head :no_content
  end

  def state
    render json: {
      mode: SPIKE_MODE,
      env: Rails.env,
      waiting: Gate.waiting,
      events: Spike::Events.all,
      pool: ActiveRecord::Base.connection_pool.stat,
      threads: Thread.list.count,
      async_executor: ActiveRecord.async_query_executor.inspect
    }
  end

  def session_probe
    render json: { late: request.session[:late], cookies: request.cookies.keys.sort }
  end

  def up
    head :ok
  end
end

Rails.application.routes.draw do
  root "pages#home"
  %w[plain slow two nested error context db db_async late_cookie timeout mw same].each do |page|
    get page, to: "pages##{page}"
  end
  post "__gate/reset", to: "probe#reset"
  post "__gate/:name/open", to: "probe#open"
  get "__state", to: "probe#state"
  get "__session", to: "probe#session_probe"
  get "up", to: "probe#up"
end
