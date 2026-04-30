# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe "Concurrent render isolation" do
    let(:manifest) do
      ClientManifest.from_hash(
        (0..7).to_h do |i|
          ["ThreadComponent#{i}", { "id" => "/tc#{i}.js",
                                    "name" => "ThreadComponent#{i}",
                                    "chunks" => ["/tc#{i}.js"] }]
        end
      )
    end

    let(:pipeline) { RenderPipeline.new(manifest) }

    # Per Story 7.1 AC4: prove thread isolation deterministically with a
    # countdown latch (Mutex+Queue) so all threads arrive at the render call
    # simultaneously, fixed seed for reproducibility, ≥4 threads to outnumber
    # typical CI cores, and ≥100 iterations to expose any race that fires
    # ≥1% of the time.
    let(:thread_count) { 4 }
    let(:iterations) { 100 }

    def run_isolation_iteration(iter, count, pipeline)
      srand(0xC0DE + iter)
      ready_latch = Queue.new
      release     = Queue.new
      results     = Array.new(count)
      results_mu  = Mutex.new

      threads = Array.new(count) do |tid|
        Thread.new do
          ctx = Object.new
          ctx.instance_variable_set(:@tid, tid)
          binding_ctx = ctx.instance_eval { binding }
          ready_latch << :ready
          release.pop
          output = pipeline.call("<ThreadComponent#{tid} thread_id={@tid} />", binding_ctx)
          results_mu.synchronize { results[tid] = output }
        end
      end

      count.times { ready_latch.pop }
      count.times { release << :go }
      threads.each(&:join)
      results
    end

    it "isolates each render's component registry from other concurrent renders" do
      iterations.times do |iter|
        results = run_isolation_iteration(iter, thread_count, pipeline)

        results.each_with_index do |output, tid|
          expect(output).to include("ThreadComponent#{tid}"),
                            "iter #{iter} thread #{tid}: missing own component"
          expect(output).to include("\"thread_id\":#{tid}")

          (0...thread_count).each do |other_tid|
            next if other_tid == tid

            expect(output).not_to include("ThreadComponent#{other_tid}"),
                                  "iter #{iter} thread #{tid} leaked ThreadComponent#{other_tid}"
          end
        end
      end
    end
  end
end
