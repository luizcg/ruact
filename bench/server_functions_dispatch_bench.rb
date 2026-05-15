# frozen_string_literal: true

# Story 8.1 — end-to-end dispatch overhead benchmark.
#
# Boots a minimal `Rails::Application` and measures the wall-clock cost
# of a full POST /__ruact/fn/:name → block return cycle against the cost
# of a comparable plain `POST /plain` action that does the same work
# (read params, render JSON). The delta is the actual overhead the gem
# adds — registry lookup + path_parameters swap + thread-local sentinel
# + the wrapper action method body.
#
# Run with:
#
#   bundle exec ruby bench/server_functions_dispatch_bench.rb
#
# Local target: ruact dispatch within ~30% of plain controller dispatch
# (the bench prints both i/s and the percentage delta). CI integration
# is deferred to a follow-up — the bench is a developer tool today, not
# a regression gate. (A gate would need a stable CI runner profile and
# an upper-bound assertion calibrated to it.)

require "bundler/setup"
require "benchmark/ips"

require "action_controller/railtie"
require "rack/test"

require "ruact"
require "ruact/controller"
require "ruact/server_functions/endpoint_controller"

class BenchApp < Rails::Application
  config.eager_load                        = false
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions   = :none
  config.logger                            = Logger.new(IO::NULL)
  config.active_support.deprecation        = :silence
  config.secret_key_base                   = "x" * 64
  config.hosts.clear if config.respond_to?(:hosts)
end

class BenchController < ActionController::Base
  include Ruact::Controller

  ruact_action(:bench_ping) { |params| { ok: true, echo: params[:value] } }

  def plain_ping
    payload = JSON.parse(request.raw_post)
    render(json: { ok: true, echo: payload["value"] })
  rescue JSON::ParserError
    render(json: { ok: true, echo: nil })
  end
end

BenchApp.routes.append do
  post "/plain", to: "bench#plain_ping"
end

BenchApp.instance.initialize!

include Rack::Test::Methods
def app = BenchApp.instance

body = { value: "hello" }.to_json
headers = { "CONTENT_TYPE" => "application/json" }

# Sanity-check both endpoints respond before measuring.
post("/__ruact/fn/bench_ping", body, headers)
raise "ruact dispatch broken (status=#{last_response.status} body=#{last_response.body})" unless last_response.status == 200

post("/plain", body, headers)
raise "plain dispatch broken (status=#{last_response.status})" unless last_response.status == 200

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)

  x.report("ruact_action dispatch") do
    post("/__ruact/fn/bench_ping", body, headers)
  end

  x.report("plain controller action") do
    post("/plain", body, headers)
  end

  x.compare!
end

def time_seconds
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
end

ruact_secs = time_seconds { 1000.times { post("/__ruact/fn/bench_ping", body, headers) } }
plain_secs = time_seconds { 1000.times { post("/plain", body, headers) } }

overhead_pct = ((ruact_secs - plain_secs) / plain_secs * 100).round(1)

puts ""
puts "1000 requests:"
puts "  ruact_action dispatch:    #{(ruact_secs * 1000).round(1)}ms total (#{(1000 / ruact_secs).round(0)} req/s)"
puts "  plain controller action:  #{(plain_secs * 1000).round(1)}ms total (#{(1000 / plain_secs).round(0)} req/s)"
puts "  overhead:                 #{overhead_pct}%"
