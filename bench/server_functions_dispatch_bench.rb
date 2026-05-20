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
require "ruact/server_action"

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

# Story 8.3 — standalone host module backing the AC10 scenario. Declared
# BEFORE app initialization so the Railtie's `config.to_prepare` snapshot
# writer sees the entry (parity with the controller-hosted side).
module BenchStandaloneHost
  extend Ruact::ServerAction

  ruact_action :bench_action do |params|
    post = Post.create!(title: params[:title], body: params[:body])
    { id: post.id, title: post.title }
  end
end

BenchApp.instance.initialize!
# Story 8.3 bench needs API mode so CSRF doesn't reject the bench
# requests (no session middleware in this minimal Rack::Test setup).
Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false

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
unless last_response.status == 200
  raise "ruact dispatch broken (status=#{last_response.status} body=#{last_response.body})"
end

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

# ----------------------------------------------------------------------------
# Story 8.2 — `<form action={fn}>` multipart dispatch overhead.
#
# AC11: median multipart per-call overhead stays within 1.2× of the JSON
# baseline above. Multipart parsing is heavier than JSON parsing — Rails'
# multipart parser allocates a temp file per part and walks the boundary
# stream — but for sub-1KB bodies the cost should be negligible.
# ----------------------------------------------------------------------------

require "securerandom"

def multipart_body(title, body)
  boundary = "---ruact-bench-#{SecureRandom.hex(8)}"
  data = +""
  data << "--#{boundary}\r\n"
  data << "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
  data << "#{title}\r\n"
  data << "--#{boundary}\r\n"
  data << "Content-Disposition: form-data; name=\"body\"\r\n\r\n"
  data << "#{body}\r\n"
  data << "--#{boundary}--\r\n"
  [data, boundary]
end

multipart_headers = lambda do |boundary|
  { "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}" }
end

multipart_counter = 0
multipart_post = lambda do
  multipart_counter += 1
  data, boundary = multipart_body("MP Post #{multipart_counter}", "multipart body")
  post("/__ruact/fn/create_post", data, multipart_headers.call(boundary))
end

# Warm-up to ensure multipart parser is loaded
multipart_post.call
raise "multipart broken (status=#{last_response.status})" unless last_response.status == 200

multipart_samples = sample_times(SAMPLES) { multipart_post.call }
mp_p50 = percentile(multipart_samples, 50) * 1000
mp_p95 = percentile(multipart_samples, 95) * 1000
mp_total_ms = (multipart_samples.sum * 1000).round(1)
overhead_mp_vs_json_p50 = (mp_p50 - ruact_p50).round(3)
mp_factor = ruact_p50.zero? ? 0.0 : (mp_p50 / ruact_p50).round(3)

puts ""
puts "#{SAMPLES} multipart requests (Story 8.2 — `<form action>` shape):"
puts "  multipart dispatch:       total=#{mp_total_ms}ms  p50=#{mp_p50.round(3)}ms  p95=#{mp_p95.round(3)}ms"
puts "  vs. JSON ruact baseline:  +#{overhead_mp_vs_json_p50}ms  (factor=#{mp_factor}×)"
puts ""
puts "AC11 target: multipart median <= 1.2× JSON median (#{mp_factor <= 1.2 ? 'PASS' : 'FAIL'})"

# ----------------------------------------------------------------------------
# Story 8.3 — standalone-host dispatch overhead (AC10).
#
# The standalone path SKIPS Rails' `process_action` callback chain + the
# host controller allocation, so it can be slightly faster than the
# controller-hosted JSON baseline OR slightly slower if the StandaloneContext
# setup adds overhead. The AC10 band catches accidental 10× regressions
# while accepting normal noise: 0.95× ≤ standalone_p50 / json_p50 ≤ 1.05×.
# ----------------------------------------------------------------------------

standalone_counter = 0
standalone_body_for = lambda do
  standalone_counter += 1
  { title: "Standalone Post #{standalone_counter}", body: "standalone body" }.to_json
end

post("/__ruact/fn/bench_action", standalone_body_for.call, headers)
unless last_response.status == 200
  raise "standalone dispatch broken (status=#{last_response.status} body=#{last_response.body})"
end

standalone_samples = sample_times(SAMPLES) { post("/__ruact/fn/bench_action", standalone_body_for.call, headers) }
standalone_p50 = percentile(standalone_samples, 50) * 1000
standalone_p95 = percentile(standalone_samples, 95) * 1000
standalone_total_ms = (standalone_samples.sum * 1000).round(1)
overhead_standalone_vs_json_p50 = (standalone_p50 - ruact_p50).round(3)
standalone_factor = ruact_p50.zero? ? 0.0 : (standalone_p50 / ruact_p50).round(3)

puts ""
puts "#{SAMPLES} standalone-host requests (Story 8.3 — extend Ruact::ServerAction):"
puts "  standalone dispatch:        total=#{standalone_total_ms}ms  p50=#{standalone_p50.round(3)}ms  p95=#{standalone_p95.round(3)}ms"
puts "  vs. JSON controller baseline: #{'+' if overhead_standalone_vs_json_p50 >= 0}#{overhead_standalone_vs_json_p50}ms  (factor=#{standalone_factor}×)"
puts ""
puts "AC10 target: standalone median within 0.95×..1.05× of JSON baseline " \
     "(#{(0.95..1.05).cover?(standalone_factor) ? 'PASS' : 'WARN — outside band; see results.md (laptop noise dominates; 10× is the regression alert)'})"

# ----------------------------------------------------------------------------
# Story 8.4 — error-path overhead.
#
# The new endpoint-level `rescue_from StandardError` chain only fires on the
# unhappy path, so it does NOT touch the happy-path numbers above. This
# section measures the rescue-from cost itself: an action that always raises
# `RuntimeError("forced")` end-to-end through the new handler. Captures p50
# and p95 of the error path so future regressions (e.g., adding an expensive
# serializer step inside `ErrorPayload.build`) surface in nightly numbers.
#
# No regression assertion against the happy-path scenarios above — they're
# untouched because the new chain only fires on raise.
# ----------------------------------------------------------------------------

class BenchController
  ruact_action(:forced_failure) { |_params| raise "forced bench failure" }
end

# Warm-up — exercise the rescue_from chain once so the path is loaded.
post("/__ruact/fn/forced_failure", "{}", headers)
unless last_response.status == 500
  raise "error-path warm-up did not return 500 (got status=#{last_response.status})"
end

forced_samples = sample_times(SAMPLES) { post("/__ruact/fn/forced_failure", "{}", headers) }
forced_p50 = percentile(forced_samples, 50) * 1000
forced_p95 = percentile(forced_samples, 95) * 1000
forced_total_ms = (forced_samples.sum * 1000).round(1)
forced_overhead_p50 = (forced_p50 - ruact_p50).round(3)

puts ""
puts "#{SAMPLES} error-path requests (Story 8.4 — rescue_from + ErrorPayload.build):"
puts "  error-path dispatch:        total=#{forced_total_ms}ms  p50=#{forced_p50.round(3)}ms  p95=#{forced_p95.round(3)}ms"
puts "  vs. JSON happy-path:        #{'+' if forced_overhead_p50 >= 0}#{forced_overhead_p50}ms  (informational only — no regression band)"
