# frozen_string_literal: true

require "bundler/setup"
require "json"

namespace :benchmark do
  desc "Run speed benchmark with benchmark-ips (development reporting)"
  task :speed do
    require "benchmark/ips"
    require "ruact"

    manifest = Ruact::ClientManifest.from_hash(
      (1..20).to_h do |i|
        ["Component#{i}", { "id" => "/assets/Component#{i}.js",
                            "name" => "Component#{i}",
                            "chunks" => ["/assets/Component#{i}.js"] }]
      end
    )
    pipeline = Ruact::RenderPipeline.new(manifest)
    erb_typical = "<div>\n#{(1..20).map { |i| "<Component#{i} index={#{i}} />" }.join("\n")}\n</div>"

    ctx = Object.new
    binding_ctx = ctx.instance_eval { binding }

    Benchmark.ips do |x|
      x.config(time: 5, warmup: 2)
      x.report("render 20 components") { pipeline.call(erb_typical, binding_ctx) }
      x.compare!
    end
  end

  desc "Run memory allocation benchmark; exits 1 if allocations exceed baseline × 1.20"
  task :memory do
    require "memory_profiler"
    require "ruact"

    manifest = Ruact::ClientManifest.from_hash(
      (1..20).to_h do |i|
        ["Component#{i}", { "id" => "/assets/Component#{i}.js",
                            "name" => "Component#{i}",
                            "chunks" => ["/assets/Component#{i}.js"] }]
      end
    )
    pipeline = Ruact::RenderPipeline.new(manifest)
    erb_typical = "<div>\n#{(1..20).map { |i| "<Component#{i} index={#{i}} />" }.join("\n")}\n</div>"
    ctx = Object.new
    binding_ctx = ctx.instance_eval { binding }

    baseline_path = File.expand_path("../../spec/benchmarks/baseline.json", __dir__)
    report = MemoryProfiler.report { pipeline.call(erb_typical, binding_ctx) }
    current = report.total_allocated

    if File.exist?(baseline_path)
      baseline = JSON.parse(File.read(baseline_path))
      limit = (baseline["typical_allocations"] * 1.20).ceil
      puts "Memory allocations: #{current} (baseline: #{baseline['typical_allocations']}, limit: #{limit})"

      if current > limit
        warn "[ruact] FAIL: allocations #{current} exceed baseline limit #{limit}"
        exit 1
      else
        puts "[ruact] PASS: allocations within 120% of baseline"
      end
    else
      baseline_data = { "typical_allocations" => current, "heavy_allocations" => nil }
      File.write(baseline_path, JSON.generate(baseline_data))
      puts "[ruact] Baseline established: #{current} allocations. Re-run to compare."
    end
  end
end
