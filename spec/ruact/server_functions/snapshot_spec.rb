# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

module Ruact
  module ServerFunctions
    RSpec.describe Snapshot, :story_8_0a do
      let(:posts_controller) { Class.new { def self.name = "PostsController" } }
      let(:cats_controller)  { Class.new { def self.name = "CategoriesController" } }
      let(:actions)          { Registry.new }
      let(:queries)          { Registry.new }
      let(:frozen_time)      { Time.utc(2026, 5, 13, 12, 34, 56) }

      describe ".dump (Story 8.0a — pure snapshot builder)" do
        it "returns the empty payload when both registries are empty" do
          snapshot = described_class.dump(actions, queries, now: frozen_time)

          expect(snapshot).to eq(
            version: 1,
            generated_at: "2026-05-13T12:34:56Z",
            functions: []
          )
        end

        it "merges action + query entries into a single functions array" do
          actions.register(:create_post, kind: :action, controller: posts_controller)
          queries.register(:categories, kind: :query, controller: cats_controller)

          snapshot = described_class.dump(actions, queries, now: frozen_time)

          expect(snapshot[:functions]).to contain_exactly(
            { "ruby_symbol" => "create_post", "js_identifier" => "createPost",
              "kind" => "action", "controller" => "PostsController" },
            { "ruby_symbol" => "categories", "js_identifier" => "categories",
              "kind" => "query", "controller" => "CategoriesController" }
          )
        end

        it "sorts functions by ruby_symbol for deterministic output (Story 8.0a)" do
          actions.register(:zeta, kind: :action, controller: posts_controller)
          actions.register(:alpha, kind: :action, controller: posts_controller)
          queries.register(:mike, kind: :query, controller: posts_controller)

          symbols = described_class.dump(actions, queries, now: frozen_time)[:functions]
                                   .map { |fn| fn["ruby_symbol"] }
          expect(symbols).to eq(%w[alpha mike zeta])
        end

        it "stringifies controller class names; falls back to nil for nil controllers" do
          actions.register(:demo_ping, kind: :action, controller: nil)
          snapshot = described_class.dump(actions, queries, now: frozen_time)
          expect(snapshot[:functions].first["controller"]).to be_nil
        end
      end

      describe ".functions_payload (Story 8.0a — fingerprint surface)" do
        it "excludes the generated_at timestamp so registry-equivalent calls match" do
          actions.register(:create_post, kind: :action, controller: posts_controller)

          first = described_class.functions_payload(actions, queries)
          sleep 0.01
          second = described_class.functions_payload(actions, queries)

          expect(first).to eq(second)
        end
      end

      describe ".generate! (Story 8.0a — write-if-changed orchestration)" do
        around do |example|
          Dir.mktmpdir do |dir|
            @tmpdir = dir
            example.run
          end
        end

        let(:path) { File.join(@tmpdir, "server-functions.json") }

        it "writes the file on first call and returns true" do
          result = described_class.generate!(
            action_registry: actions, query_registry: queries, path: path, now: frozen_time
          )

          expect(result).to be(true)
          expect(File).to exist(path)
          parsed = JSON.parse(File.read(path))
          expect(parsed.fetch("version")).to eq(1)
          expect(parsed.fetch("functions")).to eq([])
        end

        it "does NOT rewrite the file when the registry is unchanged " \
           "(Story 8.0a — pitfall #1 mitigation)", :aggregate_failures do
          actions.register(:create_post, kind: :action, controller: posts_controller)
          described_class.generate!(action_registry: actions, query_registry: queries,
                                    path: path, now: frozen_time)

          original_mtime  = File.mtime(path)
          original_bytes  = File.read(path)
          original_time   = JSON.parse(original_bytes)["generated_at"]
          sleep 1.05 # ensure mtime resolution is exceeded if we DID rewrite

          result = described_class.generate!(
            action_registry: actions, query_registry: queries,
            path: path, now: Time.now.utc # different now
          )

          expect(result).to be(false)
          expect(File.mtime(path)).to eq(original_mtime)
          expect(JSON.parse(File.read(path))["generated_at"]).to eq(original_time)
        end

        it "rewrites the file when a function is added" do
          described_class.generate!(action_registry: actions, query_registry: queries,
                                    path: path, now: frozen_time)
          actions.register(:create_post, kind: :action, controller: posts_controller)

          result = described_class.generate!(
            action_registry: actions, query_registry: queries, path: path, now: frozen_time
          )

          expect(result).to be(true)
          expect(JSON.parse(File.read(path))["functions"].size).to eq(1)
        end

        it "creates the parent directory if missing" do
          nested = File.join(@tmpdir, "deep", "nest", "server-functions.json")
          expect do
            described_class.generate!(action_registry: actions, query_registry: queries,
                                      path: nested, now: frozen_time)
          end
            .to change { File.exist?(nested) }.from(false).to(true)
        end

        it "recovers from a corrupted existing file by overwriting it" do
          File.write(path, "not json")
          result = described_class.generate!(
            action_registry: actions, query_registry: queries, path: path, now: frozen_time
          )
          expect(result).to be(true)
          expect { JSON.parse(File.read(path)) }.not_to raise_error
        end
      end
    end
  end
end
