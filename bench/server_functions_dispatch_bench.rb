# frozen_string_literal: true

# Story 8.1 — AC12 end-to-end dispatch overhead benchmark.
#
# Compares `ruact_action :create_post` against a plain controller action
# that does the SAME `Post.create!` work — per AC12's literal text:
#
#   "the script compares `ruact_action :create_post` to a plain
#   controller action that does the same `Post.create!` and prints
#   both numbers"
#   "the median ruact_action overhead is < 20ms per call"
#
# An in-memory SQLite + ActiveRecord schema (created at boot) backs the
# `Post` model so the two endpoints exercise IDENTICAL write paths —
# the only delta is the gem's dispatch wrapper (registry lookup +
# path_parameters swap + thread-local sentinel + the wrapper method).
#
# Run with:
#
#   bundle exec ruby bench/server_functions_dispatch_bench.rb
#
# Output: warm-up + benchmark-ips comparison + 1000-request absolute
# numbers + median per-call overhead in ms. AC12 target: < 20 ms.
#
# CI/nightly:
#   `.github/workflows/server-functions-bench.yml` runs this script on
#   `schedule: cron: "0 6 * * *"` (nightly) and on any PR touching
#   `lib/ruact/server_functions/**`. The workflow does NOT gate merge —
#   it posts a comment with the numbers so accidental 10× regressions
#   surface in PR feedback (per AC12: "at minimum, a non-blocking
#   nightly job").

require "bundler/setup"
require "benchmark/ips"

require "action_controller/railtie"
require "active_record"
require "sqlite3"
require "rack/test"

require "ruact"
require "ruact/controller"
require "ruact/server_functions/endpoint_controller"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :title, null: false
    t.text :body
    t.timestamps
  end
end

class Post < ActiveRecord::Base
  validates :title, presence: true
end

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

  ruact_action(:create_post) do |params|
    post = Post.create!(title: params[:title], body: params[:body])
    { id: post.id, title: post.title }
  end

  def plain_create_post
    payload = JSON.parse(request.raw_post)
    post = Post.create!(title: payload["title"], body: payload["body"])
    render(json: { id: post.id, title: post.title })
  end
end

BenchApp.routes.append do
  post "/plain", to: "bench#plain_create_post"
end

BenchApp.instance.initialize!

include Rack::Test::Methods
def app = BenchApp.instance

# Counter ensures titles stay unique under the AR validation; without
# this, repeated calls would all attempt to insert the same row and
# the bench would measure the validation-failure path, not the
# create-success path.
counter = 0
body_for = lambda do
  counter += 1
  { title: "Post #{counter}", body: "body" }.to_json
end
headers = { "CONTENT_TYPE" => "application/json" }

post("/__ruact/fn/create_post", body_for.call, headers)
raise "ruact dispatch broken (status=#{last_response.status} body=#{last_response.body})" unless last_response.status == 200

post("/plain", body_for.call, headers)
raise "plain dispatch broken (status=#{last_response.status})" unless last_response.status == 200

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)

  x.report("ruact_action dispatch (Post.create!)") do
    post("/__ruact/fn/create_post", body_for.call, headers)
  end

  x.report("plain controller action (Post.create!)") do
    post("/plain", body_for.call, headers)
  end

  x.compare!
end

# Re-run-5 (2026-05-15) — AC12 asks for MEDIAN per-call overhead, not
# mean. Sample N individual requests so we can compute the median and
# the percentile spread. The median is the load-bearing number — a few
# slow outliers (GC pause, OS scheduler) would otherwise inflate the
# mean and produce misleading regression alerts.
def time_one_seconds
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
end

def sample_times(count, &block)
  Array.new(count) { time_one_seconds(&block) }.sort
end

def percentile(sorted, pct)
  idx = (sorted.size * pct / 100).clamp(0, sorted.size - 1)
  sorted[idx]
end

SAMPLES = 1000
ruact_samples = sample_times(SAMPLES) { post("/__ruact/fn/create_post", body_for.call, headers) }
plain_samples = sample_times(SAMPLES) { post("/plain", body_for.call, headers) }

ruact_p50 = percentile(ruact_samples, 50) * 1000
plain_p50 = percentile(plain_samples, 50) * 1000
ruact_p95 = percentile(ruact_samples, 95) * 1000
plain_p95 = percentile(plain_samples, 95) * 1000
ruact_total = ruact_samples.sum
plain_total = plain_samples.sum

overhead_p50 = (ruact_p50 - plain_p50).round(3)
overhead_p95 = (ruact_p95 - plain_p95).round(3)

puts ""
puts "#{SAMPLES} requests (Post.create! body):"
puts "  ruact_action dispatch:    total=#{(ruact_total * 1000).round(1)}ms  p50=#{ruact_p50.round(3)}ms  p95=#{ruact_p95.round(3)}ms"
puts "  plain controller action:  total=#{(plain_total * 1000).round(1)}ms  p50=#{plain_p50.round(3)}ms  p95=#{plain_p95.round(3)}ms"
puts "  per-call overhead (p50):  +#{overhead_p50}ms"
puts "  per-call overhead (p95):  +#{overhead_p95}ms"
puts ""
puts "AC12 target: MEDIAN ruact_action overhead < 20 ms per call (#{overhead_p50 < 20 ? 'PASS' : 'FAIL'})"
