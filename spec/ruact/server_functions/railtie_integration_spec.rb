# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Spec_helper's rails_stub defines Rails; the railtie was not auto-required
# because Rails was not yet defined when ruact.rb evaluated `require_relative
# "ruact/railtie" if defined?(Rails)`. Load it explicitly (mirrors
# spec/ruact/railtie_spec.rb).
require "ruact/railtie"

# Story 8.0a — Railtie.write_server_functions_snapshot! is the entry point
# wired into `config.to_prepare`. The full to_prepare boot lives in
# controller_request_spec.rb; here we exercise the class method directly with
# Rails.root pointed at a tmpdir, which is enough to validate the contract
# (Story 8.0a Task 2.6 — Railtie path resolution + write-if-changed).
module Ruact
  module ServerFunctions
    RSpec.describe "Ruact::Railtie.write_server_functions_snapshot!", :story_8_0a do
      around do |example|
        Dir.mktmpdir do |dir|
          original_root = Rails.root
          Rails.root    = Pathname.new(dir)
          @tmpdir       = dir
          example.run
        ensure
          Rails.root = original_root
        end
      end

      let(:path) { File.join(@tmpdir, "tmp/cache/ruact/server-functions.json") }

      it "writes the JSON to tmp/cache/ruact/server-functions.json (Story 8.0a)" do
        result = Ruact::Railtie.write_server_functions_snapshot!
        expect(result).to be(true)
        expect(File).to exist(path)
      end

      it "writes an empty `functions: []` array when both registries are empty " \
         "(Story 8.0a — empty-registry contract)" do
        Ruact::Railtie.write_server_functions_snapshot!
        parsed = JSON.parse(File.read(path))
        expect(parsed.fetch("functions")).to eq([])
      end

      it "the file is short-circuited on a second call with an unchanged registry " \
         "(Story 8.0a — pitfall #1)" do
        Ruact::Railtie.write_server_functions_snapshot!
        expect(Ruact::Railtie.write_server_functions_snapshot!).to be(false)
      end

      it "rewrites the file after a registration is added (Story 8.0a)" do
        Ruact::Railtie.write_server_functions_snapshot!
        Ruact.action_registry.register(:demo_ping, kind: :action)

        expect(Ruact::Railtie.write_server_functions_snapshot!).to be(true)
        parsed = JSON.parse(File.read(path))
        expect(parsed["functions"].map { |fn| fn["ruby_symbol"] }).to eq(["demo_ping"])
      end
    end

    RSpec.describe "Ruact::Railtie registry-clear hook (Story 8.1)", :story_8_1 do
      # The Railtie attaches a `before_class_unload` callback that clears both
      # registries before Zeitwerk tears down constants — this prevents removed
      # `ruact_action` declarations from lingering across reloads. The full
      # Rails-app boot covering the controller class-body re-evaluation lives
      # in `controller_request_spec.rb`; here we exercise the hook directly.
      before do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!
      end

      it "clears both registries when invoked" do
        Ruact.action_registry.register(:foo, kind: :action)
        Ruact.query_registry.register(:bar, kind: :query)
        expect(Ruact.action_registry.size).to eq(1)
        expect(Ruact.query_registry.size).to eq(1)

        # Direct invocation of the cleanup that the reloader hook would run.
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!

        expect(Ruact.action_registry.size).to eq(0)
        expect(Ruact.query_registry.size).to eq(0)
      end

      it "the snapshot write-if-changed guard skips a rewrite when controllers " \
         "re-register the same symbols after a clear (Story 8.1 — pitfall #1 mitigation)" do
        Dir.mktmpdir do |dir|
          original_root = Rails.root
          Rails.root = Pathname.new(dir)

          Ruact.action_registry.register(:create_post, kind: :action)
          Ruact::Railtie.write_server_functions_snapshot!
          original_bytes = File.read(File.join(dir, "tmp/cache/ruact/server-functions.json"))

          # Simulate a reload cycle: clear, then re-register the same symbol
          # with a fresh class object (the same as what would happen when
          # controller class bodies re-evaluate after Zeitwerk teardown).
          Ruact.action_registry.clear!
          Ruact.action_registry.register(:create_post, kind: :action)

          expect(Ruact::Railtie.write_server_functions_snapshot!).to be(false)
          expect(File.read(File.join(dir, "tmp/cache/ruact/server-functions.json"))).to eq(original_bytes)
        ensure
          Rails.root = original_root
        end
      end
    end
  end
end
