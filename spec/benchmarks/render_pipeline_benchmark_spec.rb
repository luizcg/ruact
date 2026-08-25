# frozen_string_literal: true

require "spec_helper"
require "rspec-benchmark"
require "memory_profiler"
require "json"

BENCHMARK_BASELINE_FILE = File.expand_path("baseline.json", __dir__)

# The baseline is a SINGLE measurement shared by every matrix cell, while the
# same render allocates differently per Ruby/Rails combination — measured at
# ~9% spread (Ruby 3.4/Rails 8.1: 1792; Ruby 3.3/Rails 7.1: ~1958). The x1.20
# tolerance therefore absorbs two different things at once: that cross-version
# spread AND real growth. When the two together cross the limit, ONE cell goes
# red while the rest stay green, which reads like flakiness and is not — rerunning
# does not fix it.
#
# Before rebaselining, check WHICH it is. A number that moved with a code change
# is a regression and belongs in the diff, not in this file. A number that drifted
# across many changes has outgrown its anchor, and the honest move is to rebaseline
# and record the growth in baseline.json's `_history` (see the 2026-08-25 entry).
#
# To regenerate: delete baseline.json and run this file TWICE (the first run writes
# `typical_allocations`, the second fills `heavy_allocations`), then restore the
# `_measured_on` / `_history` keys, which the spec does not write.

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
    active_pipeline.render({ erb: erb_source, binding: ctx.instance_eval { binding } }, mode: :string)
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
