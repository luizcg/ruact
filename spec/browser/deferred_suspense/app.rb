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
require_relative "control"

%w[tmp log results].each { |dir| FileUtils.mkdir_p(File.join(__dir__, dir)) }

ENV["DATABASE_URL"] ||= "sqlite3:#{File.join(__dir__, 'tmp', "harness-#{ENV.fetch('PORT', '0')}.sqlite3")}?pool=10"
# Story 19-2 (AC13) — `./run pg` points DATABASE_URL at a throwaway PostgreSQL.
POSTGRES = ENV["DATABASE_URL"].start_with?("postgres")
require "pg" if POSTGRES

# Story 19-2 (AC17.1) — a primary and a replica, as `rails g
# active_record:multi_db` sets them up; the replica is the same database.
DATABASE_YML = File.join(__dir__, "tmp", "database.yml")
File.write(DATABASE_YML, <<~YAML)
  #{ENV.fetch('RAILS_ENV', 'development')}:
    primary:
      url: <%= ENV["DATABASE_URL"] %>
    primary_replica:
      url: <%= ENV["DATABASE_URL"] %>
      replica: true
YAML
require "active_record/middleware/database_selector"

# Rails' DatabaseSelector (`config.active_record.database_selector`), for the
# role pages only: everywhere else a GET that writes would be refused.
class RoleSelector < ActiveRecord::Middleware::DatabaseSelector
  def call(env)
    env["PATH_INFO"].start_with?("/role") ? super : @app.call(env)
  end
end

module Harness
  # What happened on the server, in order, for the tests to read: what the
  # views record, what ruact logs, what Rails.error is told.
  module Events
    @mutex = Mutex.new
    @all = []

    # What a request of an earlier scenario, woken by the reset, records is
    # left out.
    def self.add(event)
      generation = Thread.current[:harness_generation]
      return nil if generation && generation != Gate.generation

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

  # Story 19-2 (AC13) — PostgreSQL's gate: a query waits in `harness_gate(n)`
  # for an advisory lock the test holds on a connection of its own, outside the
  # app's pool; who is waiting is read from pg_stat_activity.
  module PgGate
    @mutex = Mutex.new

    def self.connection
      # `pool` is Active Record's, not libpq's.
      @connection ||= PG.connect(ENV.fetch("DATABASE_URL").sub(/[&?]pool=\d+/, ""))
    end

    def self.hold(number)
      @mutex.synchronize { connection.exec_params("SELECT pg_advisory_lock($1)", [number]) }
    end

    def self.release(number)
      @mutex.synchronize { connection.exec_params("SELECT pg_advisory_unlock($1)", [number]) }
    end

    def self.reset
      @mutex.synchronize { connection.exec("SELECT pg_advisory_unlock_all()") } if POSTGRES
    end

    # Queries of the app's, waiting at a gate or running; and waiting at gate
    # 1 and at gate 2.
    def self.activity
      return {} unless POSTGRES

      @mutex.synchronize do
        rows = connection.exec(<<~SQL).to_a
          SELECT count(*) FILTER (WHERE wait_event = 'advisory') AS waiting,
                 count(*) FILTER (WHERE wait_event = 'advisory' AND query LIKE '%harness_gate(1)%') AS waiting_1,
                 count(*) FILTER (WHERE wait_event = 'advisory' AND query LIKE '%harness_gate(2)%') AS waiting_2,
                 count(*) FILTER (WHERE state = 'active') AS active
          FROM pg_stat_activity
          WHERE pid <> pg_backend_pid() AND datname = current_database() AND query LIKE '%harness_gate%'
        SQL
        rows.first.transform_values(&:to_i)
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
    # The scenario this request belongs to (a Live thread gets a copy).
    Thread.current[:harness_generation] = Gate.generation
    Thread.current[:harness_fiber_local] = "set"
    Thread.current.thread_variable_set(:harness_thread_variable, "set")
    return @app.call(env) unless env["PATH_INFO"] == "/context_mw"

    # Story 19-2 (AC17) — what a middleware scopes around the app: a locale
    # (rack-contrib's Rack::Locale and others), a tenant, a database role
    # (what Rails' DatabaseSelector does with connected_to).
    I18n.with_locale(:pt) do
      Tenant.with("from a middleware") do
        ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true) { @app.call(env) }
      end
    end
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
  # Story 19-2 (AC9) — fragment caching on, for the page with `cache` around a <Suspense>.
  config.action_controller.perform_caching = true
  if Rails.env.development?
    config.server_timing = true
    config.assets.quiet = true
    config.active_record.migration_error = :page_load
  else
    config.assume_ssl = true
    config.force_ssl = true
    config.ssl_options = { hsts: false } # the browser runs it on http://localhost
    # assume_ssl makes the request https while the browser is on http: a form's
    # Origin (http://…) never matches. Only the harness has that mismatch.
    config.action_controller.forgery_protection_origin_check = false
    config.silence_healthcheck_path = "/up"
  end
  config.logger = ActiveSupport::BroadcastLogger.new(
    ActiveSupport::Logger.new(File.join(__dir__, "log", "#{Rails.env}.log")), Harness::RuactLog.new
  )
  config.log_level = :info
  config.i18n.available_locales = %i[en pt]
  config.i18n.default_locale = :en
  config.middleware.use ThreadMarker
  config.paths.add "config/database", with: DATABASE_YML
  config.middleware.use RoleSelector, ActiveRecord::Middleware::DatabaseSelector::Resolver,
                        ActiveRecord::Middleware::DatabaseSelector::Resolver::Session, { delay: 2.seconds }
  config.active_record.async_query_executor = :global_thread_pool if ENV["HARNESS_ASYNC"] == "1"

  # Story 19-2 (AC21) — HARNESS_CSP=1: a policy that allows scripts by nonce
  # only (no 'unsafe-inline'), as an app with `content_security_policy_nonce_generator` has.
  if ENV["HARNESS_CSP"] == "1"
    vite = "http://localhost:#{ENV.fetch('VITE_PORT', '5199')}"
    config.content_security_policy do |policy|
      policy.default_src :self
      policy.script_src(*[:self, (vite if Rails.env.development?)].compact)
      policy.connect_src(*[:self, (vite if Rails.env.development?), (vite.sub("http", "ws") if Rails.env.development?)].compact)
      policy.style_src :self, :unsafe_inline
      policy.img_src :self, :data
    end
    config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
    config.content_security_policy_nonce_directives = %w[script-src]
  end
end

Ruact.configure do |config|
  config.layout = "ruact"
  config.vite_dev_server = "http://localhost:#{ENV.fetch('VITE_PORT', '5199')}"
  # Scenarios synchronise on gates, not time: the timeout must not end a block
  # a scenario is still holding at a gate. HARNESS_TIMEOUT sets it for the ones
  # that measure it.
  config.suspense_timeout = Float(ENV["HARNESS_TIMEOUT"].presence || "30")
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

Control.start(Integer(ENV["HARNESS_CONTROL_PORT"], 10)) if ENV["HARNESS_CONTROL_PORT"].present?

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
if POSTGRES
  ActiveRecord::Base.connection.execute(<<~SQL)
    CREATE OR REPLACE FUNCTION harness_gate(gate bigint) RETURNS boolean LANGUAGE plpgsql AS $$
    BEGIN PERFORM pg_advisory_xact_lock_shared(gate); RETURN true; END $$
  SQL
end

# Story 19-2 (AC5): the failure the test arms, at the second boundary — after
# the shell was written, outside any block.
Ruact::DeferredRender.prepend(Module.new do
  def next_rows
    raise "the stream failed after the first write" if Harness::FailStream.now?

    super
  end
end)

# Story 19-2 (AC21) — the CSP perturbation: the rows of each boundary pushed
# without the nonce. The content must then never arrive.
if ENV["HARNESS_CSP_PERTURB"] == "1"
  Ruact::Controller::Delivery.prepend(Module.new do
    private

    def __ruact_flight_push(rows, _open = nil) = super(rows)
  end)
end

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

ActiveRecord::Base.connects_to database: { writing: :primary, reading: :primary_replica }

class Item < ActiveRecord::Base
  validates :name, length: { minimum: 3 }
end

Item.create!(name: "one")
Item.create!(name: "two")
ActiveRecord::Base.connection_pool.disconnect!

class PagesController < ApplicationController
  # Every page streams but `plain`, which shows that an action left out keeps
  # the request's thread.
  ruact_streaming except: :plain

  around_action :scoped, only: :context
  # Story 19-2 (AC16.1) — the whole action in a transaction, as some apps do.
  around_action(only: :tx_around) do |_controller, action|
    Item.transaction do
      action.call
      Harness::Events.add("transaction about to commit")
    end
  end
  # Story 19-2 (AC17.1) — the fix for a role a middleware chose: set it in the controller.
  around_action(only: :role_fixed) do |_controller, action|
    ActiveRecord::Base.connected_to(role: :reading) { action.call }
  end
  # Story 19-2 (AC6) — an after_action that writes once the page was sent.
  after_action(only: :after_write) do
    cookies[:after] = "1"
    response.headers["X-After"] = "1"
    Harness::Events.add("after_write ran")
  end
  after_action(only: :context) { Harness::Events.add("after_action") }

  # The end of the action, after ruact's own `ensure` (the check of what was
  # written after the page was sent, the connections given back): a barrier
  # for what a test reads of a request that has finished.
  def process_action(*)
    super
  ensure
    Harness::Events.add("action done:#{action_name}")
  end

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
  def inside; end
  def mixed; end
  def pg_slow; end
  def pg_statement; end
  def pg_transaction; end
  def tx_around; end

  # Story 19-2 (AC17) — the context page, scoped by a middleware and not by
  # the controller.
  def context_mw; end
  def cached; end
  def tx_block; end

  # Story 19-2 (AC16.3) — a transaction begun on the connection and never
  # closed, streamed (this action) and not (`tx_left_open_plain`).
  def tx_left_open
    Item.connection.begin_db_transaction
    Item.connection.execute("INSERT INTO items (name) VALUES ('left open')")
  end

  def tx_left_open_plain
    Item.connection.begin_db_transaction
    Item.connection.execute("INSERT INTO items (name) VALUES ('left open')")
    render json: { ok: true }
  end

  # Story 19-2 (AC16.4) — the connection taken by the action, and a block's query.
  def leased_block
    Item.connection.select_value("SELECT 1")
  end

  # Story 19-2 (AC15) — two queries started early, each held at its own gate.
  def pg_async
    @first = Item.where("harness_gate(1)").load_async
    @second = Item.where("harness_gate(2)").load_async
  end

  def after_write; end

  # Story 19-2 (AC17.1) — the role DatabaseSelector chose, read in the shell
  # and in a block; then with the role set in the controller.
  def role; end
  def role_fixed; end
  def cache_inside; end
  def partials; end
  def content_for_block; end

  # Story 19-2 (AC12) — who, where and when come from the request, so two at
  # once can differ.
  def context
    Current.user = params[:user] || "ada"
  end

  # A slow query inside the block: a lazy relation, loaded where the view walks
  # it. Held at gate `a`, or at PostgreSQL's gate 1.
  def db
    @items = Item.where(POSTGRES ? "harness_gate(1)" : "gate_wait('a') = 1")
  end

  private

  def scoped(&)
    I18n.with_locale(params[:locale] || :pt) do
      Time.use_zone(params[:zone] || "Tokyo") do
        Tenant.with(params[:tenant] || "acme", &)
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
    # A request the reset woke records its end: before the next scenario starts.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.01 until Gate.waiting.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    Harness::Events.clear
    Harness::Once.clear
    Harness::FailStream.clear
    Harness::PgGate.reset
    Rails.cache.clear
    head :no_content
  end

  def state
    render json: {
      env: Rails.env,
      waiting: Gate.waiting,
      events: Harness::Events.all,
      pool: ActiveRecord::Base.connection_pool.stat,
      i18n: I18n::VERSION,
      pg: Harness::PgGate.activity
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

  def pg_hold
    Harness::PgGate.hold(Integer(params[:gate], 10))
    head :no_content
  end

  def pg_release
    Harness::PgGate.release(Integer(params[:gate], 10))
    head :no_content
  end

  # Story 19-2 (AC16) — what the database holds: the items, and whether a
  # connection the pool hands out now sees an open transaction.
  def db_state
    connection = ActiveRecord::Base.connection_pool.checkout
    render json: { names: Item.pluck(:name), open_transaction_on_checkout: connection.raw_connection.transaction_active? }
  ensure
    ActiveRecord::Base.connection_pool.checkin(connection) if connection
  end

  # Story 19-2 (AC16.3) — undo what a scenario left open, so the next one can write.
  def db_rollback
    ActiveRecord::Base.connection_pool.connections.each do |connection|
      raw = connection.raw_connection
      raw.rollback if raw.respond_to?(:transaction_active?) && raw.transaction_active?
    end
    head :no_content
  end

  # A quick query, timed by the test: does it wait for one left running?
  def pg_quick
    render json: { count: Item.count }
  end

  # Story 19-2 (AC3.3) — something the document is still loading when the
  # router leaves it: an image, a fetch, a module, each held at its own gate.
  PIXEL = ["89504e470d0a1a0a0000000d4948445200000001000000010806000000" \
           "1f15c4890000000d49444154789c63606060f80f00010401005fe5c34b0000000049454e44ae426082"].pack("H*")
  HELD = { "png" => "image/png", "js" => "text/javascript" }.freeze

  def held
    Gate.wait(params[:name])
    case params[:format]
    when "png" then send_data PIXEL, type: HELD["png"], disposition: "inline"
    when "js" then render plain: %(export const value = "#{params[:name]}";\n), content_type: HELD["js"]
    else render plain: "held:#{params[:name]}"
    end
  end
end

Rails.application.routes.draw do
  root "pages#home"
  %w[plain slow two nested error context db late_cookie leased flaky errors after_write inside mixed pg_slow pg_statement pg_transaction
     pg_async tx_around tx_block tx_left_open tx_left_open_plain leased_block context_mw cached role role_fixed cache_inside partials
     content_for_block].each do |page|
    get page, to: "pages##{page}"
  end
  post "__gate/reset", to: "probe#reset"
  post "__gate/:name/open", to: "probe#open"
  get "__state", to: "probe#state"
  get "__session", to: "probe#session_probe"
  get "up", to: "probe#up"
  post "__fail_stream", to: "probe#fail_stream"
  post "__pg/:gate/hold", to: "probe#pg_hold"
  post "__pg/:gate/release", to: "probe#pg_release"
  get "__pg/quick", to: "probe#pg_quick"
  get "__db", to: "probe#db_state"
  post "__db/rollback", to: "probe#db_rollback"
  get "__held/:name", to: "probe#held"
  get "items/new", to: "items#new"
  post "items", to: "items#create"
  post "items/in_place", to: "items#create_in_place"
  post "items/redirect", to: "items#create_redirect"
end
