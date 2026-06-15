# frozen_string_literal: true

# Story 9.9 — NFR21 dispatch-overhead benchmark, re-pointed at REAL routes.
#
# The v1 substrate (the synthetic `POST /__ruact/fn/:name` endpoint + the
# `ruact_action` DSL) was demolished, so this bench now exercises the
# route-driven (v2) contract:
#
#   - A non-GET REST route (`POST /posts`) on a controller that does
#     `include Ruact::Server` — Bucket-2 JSON dispatch (the generated accessor
#     sends `Accept: application/json`), compared against a plain controller
#     doing the SAME `Post.create!`. The only delta is the concern's callback
#     chain (the structured-error `rescue_from` + the upload guard).
#   - The multipart (`<form action>`) shape on the same route.
#   - A query route (`GET /q/<jsId>`) drawn by `ruact_queries`.
#
# NFR21 budget: server-function dispatch adds < 20ms over a standard Rails
# request. NOTE (Story 9.9 D2): the v2 path is a REAL Rails route through the
# full router + the `Ruact::Server` concern — a different code path than the
# deleted v1 synthetic endpoint, so there is no apples-to-apples per-call delta
# against the historical v1 baseline. The honest gate is "p50/p95 < 20ms holds."
#
# v1 baseline (historical, Story 9.1, 2026-06-05): ruact_action JSON dispatch
# p50 0.973ms / p95 1.344ms; plain p50 0.771ms / p95 1.058ms; overhead +0.202ms
# p50 / +0.286ms p95; multipart p50 1.05ms / p95 1.494ms — all PASS < 20ms.
#
# Run with:
#   bundle exec ruby bench/server_functions_dispatch_bench.rb
#
# CI/nightly: `.github/workflows/server-functions-bench.yml` runs this on a
# nightly cron + any PR touching `lib/ruact/server_functions/**`. Non-blocking.

require "bundler/setup"
require "benchmark/ips"

require "action_controller/railtie"
require "active_record"
require "sqlite3"
require "rack/test"

require "ruact"
require "ruact/controller"
require "ruact/server"
require "ruact/routing"
require "ruact/query"

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

# No host ApplicationController in this minimal bench — point query dispatch at
# ActionController::Base so `ruact_queries` resolves its parent controller.
Ruact.configure { |c| c.query_parent_controller = "ActionController::Base" }

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

# v2 mutation host — a normal controller that includes Ruact::Server. The
# `create` action is a non-GET REST route; the generated accessor calls it with
# `Accept: application/json`, so the concern serves Bucket-2 JSON.
class PostsController < ActionController::Base
  include Ruact::Server

  def create
    payload = JSON.parse(request.raw_post)
    @post = Post.create!(title: payload["title"], body: payload["body"])
    render(json: { id: @post.id, title: @post.title })
  end

  # Multipart (`<form action={fn}>`) dispatch on the SAME Ruact::Server host:
  # the request still flows through the concern (upload guard + error gate +
  # Accept negotiation) — reads Rack-parsed multipart params.
  def create_multipart
    @post = Post.create!(title: params[:title], body: params[:body])
    render(json: { id: @post.id, title: @post.title })
  end
end

# Plain baseline — same Post.create! work, no concern. `create_multipart` reads
# Rack-parsed multipart params (the `<form action>` wire shape).
class PlainController < ActionController::Base
  def create
    payload = JSON.parse(request.raw_post)
    post = Post.create!(title: payload["title"], body: payload["body"])
    render(json: { id: post.id, title: post.title })
  end

  def create_multipart
    post = Post.create!(title: params[:title], body: params[:body])
    render(json: { id: post.id, title: post.title })
  end
end

# v2 read host — a Ruact::Query mounted via ruact_queries → GET /q/<jsId>.
class CatalogQuery < Ruact::Query
  def recent
    Post.order(created_at: :desc).limit(5).pluck(:title)
  end
end

BenchApp.routes.append do
  post "/posts", to: "posts#create"
  post "/posts_mp", to: "posts#create_multipart"
  post "/plain", to: "plain#create"
  post "/plain_mp", to: "plain#create_multipart"
  ruact_queries CatalogQuery
end

BenchApp.instance.initialize!
# API mode so CSRF doesn't reject the bench requests (no session middleware in
# this minimal Rack::Test setup).
PostsController.allow_forgery_protection = false

include Rack::Test::Methods

def app = BenchApp.instance

counter = 0
body_for = lambda do
  counter += 1
  { title: "Post #{counter}", body: "body" }.to_json
end
json_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }

post("/posts", body_for.call, json_headers)
unless last_response.status == 200
  raise "ruact server dispatch broken (status=#{last_response.status} body=#{last_response.body})"
end

post("/plain", body_for.call, json_headers)
raise "plain dispatch broken (status=#{last_response.status})" unless last_response.status == 200

get("/q/recent", {}, { "HTTP_ACCEPT" => "application/json" })
raise "query dispatch broken (status=#{last_response.status})" unless last_response.status == 200

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)

  x.report("Ruact::Server dispatch (POST /posts, Post.create!)") do
    post("/posts", body_for.call, json_headers)
  end

  x.report("plain controller action (Post.create!)") do
    post("/plain", body_for.call, json_headers)
  end

  x.compare!
end

# NFR21 asks for the MEDIAN per-call number. Sample N individual requests so we
# can compute the median + the percentile spread; the median is load-bearing (a
# few GC/scheduler outliers would inflate the mean).
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
ruact_samples = sample_times(SAMPLES) { post("/posts", body_for.call, json_headers) }
plain_samples = sample_times(SAMPLES) { post("/plain", body_for.call, json_headers) }

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
puts "  Ruact::Server dispatch:   total=#{(ruact_total * 1000).round(1)}ms  p50=#{ruact_p50.round(3)}ms  p95=#{ruact_p95.round(3)}ms"
puts "  plain controller action:  total=#{(plain_total * 1000).round(1)}ms  p50=#{plain_p50.round(3)}ms  p95=#{plain_p95.round(3)}ms"
puts "  per-call overhead (p50):  +#{overhead_p50}ms"
puts "  per-call overhead (p95):  +#{overhead_p95}ms"
puts ""
puts "NFR21 target: MEDIAN Ruact::Server dispatch p50/p95 < 20 ms per call " \
     "(p50 #{ruact_p50.round(3)}ms #{ruact_p50 < 20 ? 'PASS' : 'FAIL'}, " \
     "p95 #{ruact_p95.round(3)}ms #{ruact_p95 < 20 ? 'PASS' : 'FAIL'})"

# ----------------------------------------------------------------------------
# Multipart (`<form action={fn}>`) dispatch overhead on the same route.
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
  post("/posts_mp", data, multipart_headers.call(boundary))
end

multipart_post.call
raise "multipart broken (status=#{last_response.status})" unless last_response.status == 200

multipart_samples = sample_times(SAMPLES) { multipart_post.call }
mp_p50 = percentile(multipart_samples, 50) * 1000
mp_p95 = percentile(multipart_samples, 95) * 1000
mp_total_ms = (multipart_samples.sum * 1000).round(1)

puts ""
puts "#{SAMPLES} multipart requests (`<form action>` shape) — Ruact::Server route /posts_mp:"
puts "  Ruact::Server multipart dispatch:  total=#{mp_total_ms}ms  p50=#{mp_p50.round(3)}ms  p95=#{mp_p95.round(3)}ms"
puts ""
puts "NFR21 target: multipart p50/p95 < 20 ms per call " \
     "(p50 #{mp_p50.round(3)}ms #{mp_p50 < 20 ? 'PASS' : 'FAIL'}, " \
     "p95 #{mp_p95.round(3)}ms #{mp_p95 < 20 ? 'PASS' : 'FAIL'})"

# ----------------------------------------------------------------------------
# Query dispatch overhead — GET /q/<jsId> (a ruact_queries-mounted read).
# ----------------------------------------------------------------------------

query_get = -> { get("/q/recent", {}, { "HTTP_ACCEPT" => "application/json" }) }
query_get.call
raise "query broken (status=#{last_response.status})" unless last_response.status == 200

query_samples = sample_times(SAMPLES) { query_get.call }
q_p50 = percentile(query_samples, 50) * 1000
q_p95 = percentile(query_samples, 95) * 1000
q_total_ms = (query_samples.sum * 1000).round(1)

puts ""
puts "#{SAMPLES} query requests (GET /q/recent):"
puts "  query dispatch:           total=#{q_total_ms}ms  p50=#{q_p50.round(3)}ms  p95=#{q_p95.round(3)}ms"
puts ""
puts "NFR21 target: query p50/p95 < 20 ms per call " \
     "(p50 #{q_p50.round(3)}ms #{q_p50 < 20 ? 'PASS' : 'FAIL'}, " \
     "p95 #{q_p95.round(3)}ms #{q_p95 < 20 ? 'PASS' : 'FAIL'})"
