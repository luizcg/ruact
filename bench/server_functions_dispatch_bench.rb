# frozen_string_literal: true

# Story 8.1 — microbenchmark for the server-functions dispatch fast path.
#
# Measures the per-call overhead of the operations the gem adds beyond a
# regular Rails action: registry lookup, naming-bridge resolution, and
# the snake_case ↔ camelCase identifier translation.
#
# Run with:
#
#   bundle exec ruby bench/server_functions_dispatch_bench.rb
#
# Targets a baseline of >50k iterations/sec for each operation on
# commodity hardware (these are pure Ruby Hash#[]/regex ops, so they
# should never become the bottleneck of a request).

require "bundler/setup"
require "benchmark/ips"
require "ruact"
require "ruact/server_functions/registry"
require "ruact/server_functions/name_bridge"

registry = Ruact::ServerFunctions::Registry.new

50.times do |i|
  name = :"action_#{i}"
  registry.register(name, kind: :action, controller: Object) { |_p| nil }
end

needle = :action_25

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)

  x.report("registry: known lookup") do
    registry.entries[needle]
  end

  x.report("registry: unknown lookup") do
    registry.entries[:not_registered]
  end

  x.report("name_bridge: to_js_identifier") do
    Ruact::ServerFunctions::NameBridge.to_js_identifier(:create_post)
  end

  x.compare!
end
