# frozen_string_literal: true

require "spec_helper"
require "ruact/server_functions/backtrace_cleaner"

module Ruact
  module ServerFunctions
    RSpec.describe BacktraceCleaner, :story_8_4 do
      describe "Story 8.4 — .split classifies frames by Ruact.gem_path prefix" do
        let(:gem_root) { "/tmp/ruact-test-gem" }

        before { allow(Ruact).to receive(:gem_path).and_return(gem_root) }

        it "puts non-gem frames into :app, preserving order" do
          frames = [
            "/Users/dev/host/app/controllers/posts_controller.rb:12:in `create'",
            "/Users/dev/host/app/models/post.rb:7:in `save!'"
          ]
          expect(described_class.split(frames)).to eq(
            app: frames,
            gem: []
          )
        end

        it "puts frames under Ruact.gem_path into :gem, preserving order" do
          frames = [
            "#{gem_root}/lib/ruact/server_functions/endpoint_controller.rb:111:in `dispatch'",
            "#{gem_root}/lib/ruact/server_functions/standalone_dispatcher.rb:42:in `apply'"
          ]
          expect(described_class.split(frames)).to eq(
            app: [],
            gem: frames
          )
        end

        it "interleaves app+gem frames into separate buckets while preserving relative order in each bucket" do
          frames = [
            "/Users/dev/host/app/controllers/posts_controller.rb:12:in `create'",
            "#{gem_root}/lib/ruact/server_functions/endpoint_controller.rb:111:in `dispatch'",
            "/Users/dev/host/app/models/post.rb:7:in `save!'",
            "#{gem_root}/lib/ruact/server_functions/standalone_dispatcher.rb:42:in `apply'"
          ]
          result = described_class.split(frames)
          expect(result[:app]).to eq([frames[0], frames[2]])
          expect(result[:gem]).to eq([frames[1], frames[3]])
        end

        it "returns { app: [], gem: [] } for nil input" do
          expect(described_class.split(nil)).to eq(app: [], gem: [])
        end

        it "returns { app: [], gem: [] } for an empty array" do
          expect(described_class.split([])).to eq(app: [], gem: [])
        end

        it "classifies a frame whose path is exactly Ruact.gem_path as GEM (edge case)" do
          frames = ["#{gem_root}:0:in `<top>'"]
          expect(described_class.split(frames)).to eq(app: [], gem: frames)
        end
      end
    end
  end
end
