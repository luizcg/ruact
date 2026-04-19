# frozen_string_literal: true

require "spec_helper"
require "rspec-benchmark"
require "memory_profiler"
require "json"

BENCHMARK_BASELINE_FILE = File.expand_path("baseline.json", __dir__)

RSpec.describe "RenderPipeline benchmark" do
  include RSpec::Benchmark::Matchers

  let(:baseline_file) { BENCHMARK_BASELINE_FILE }

  let(:manifest) do
    entries = (1..20).to_h do |i|
      ["Component#{i}", {
        "id" => "/assets/Component#{i}.js",
        "name" => "Component#{i}",
        "chunks" => ["/assets/Component#{i}.js"]
      }]
    end
    Ruact::ClientManifest.from_hash(entries)
  end

  let(:pipeline) { Ruact::RenderPipeline.new(manifest) }

  def make_erb(count)
    components = (1..count).map { |i| "<Component#{i} index={#{i}} />" }.join("\n")
    "<div>\n#{components}\n</div>"
  end

  def render_erb(erb_source, active_pipeline = pipeline)
    ctx = Object.new
    active_pipeline.call(erb_source, ctx.instance_eval { binding })
  end

  describe "typical view (20 components)" do
    let(:erb_typical) { make_erb(20) }

    it "allocates fewer than the baseline × 1.20 objects" do
      report = MemoryProfiler.report { render_erb(erb_typical) }
      allocations = report.total_allocated

      if File.exist?(baseline_file)
        baseline = JSON.parse(File.read(baseline_file))
        limit = (baseline["typical_allocations"] * 1.20).ceil
        expect(allocations).to be <= limit,
                               "Typical view allocations #{allocations} exceed baseline limit #{limit} " \
                               "(baseline: #{baseline['typical_allocations']})"
      else
        # First run — establish baseline
        File.write(baseline_file, JSON.generate("typical_allocations" => allocations,
                                                "heavy_allocations" => nil))
      end
    end
  end

  describe "heavy view (100 components)" do
    let(:manifest_heavy) do
      entries = (1..100).to_h do |i|
        ["Component#{i}", {
          "id" => "/assets/Component#{i}.js",
          "name" => "Component#{i}",
          "chunks" => ["/assets/Component#{i}.js"]
        }]
      end
      Ruact::ClientManifest.from_hash(entries)
    end

    let(:pipeline_heavy) { Ruact::RenderPipeline.new(manifest_heavy) }
    let(:erb_heavy)      { make_erb(100) }

    it "allocates fewer than the baseline × 1.20 objects" do
      report = MemoryProfiler.report { render_erb(erb_heavy, pipeline_heavy) }
      allocations = report.total_allocated

      if File.exist?(baseline_file)
        data = JSON.parse(File.read(baseline_file))
        if data["heavy_allocations"]
          limit = (data["heavy_allocations"] * 1.20).ceil
          expect(allocations).to be <= limit,
                                 "Heavy view allocations #{allocations} exceed baseline limit #{limit} " \
                                 "(baseline: #{data['heavy_allocations']})"
        else
          data["heavy_allocations"] = allocations
          File.write(baseline_file, JSON.generate(data))
        end
      end
    end
  end
end
