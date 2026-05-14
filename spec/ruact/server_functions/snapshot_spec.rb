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

      describe ".functions_payload — cross-registry collision (Chunk1 Blocker 2026-05-13)" do
        it "raises Ruact::ConfigurationError shaped per AC7 when an action and a query " \
           "share a JS identifier (Re-run patch 2026-05-14 — message prefix aligned with " \
           "within-registry collision)",
           :aggregate_failures do
          actions.register(:foo, kind: :action, controller: posts_controller)
          queries.register(:foo, kind: :query, controller: cats_controller)
          expect { described_class.functions_payload(actions, queries) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              # AC7 prefix: rake wraps to "[ruact] error: server-function naming collision: ..."
              expect(error.message).to start_with("server-function naming collision:")
              expect(error.message).to include(":foo")
              expect(error.message).to include(":action")
              expect(error.message).to include(":query")
              expect(error.message).to include("PostsController")
              expect(error.message).to include("CategoriesController")
              expect(error.message).to include('"foo"')
            end
        end

        it "raises when different Ruby symbols cross-collide via the naming bridge" do
          # `:foo_bar` action + `:foo__bar` query both → "fooBar"
          actions.register(:foo_bar, kind: :action, controller: posts_controller)
          queries.register(:foo__bar, kind: :query, controller: cats_controller)
          expect { described_class.functions_payload(actions, queries) }
            .to raise_error(Ruact::ConfigurationError, /server-function naming collision.*"fooBar"/m)
        end

        it "raises when both registries contain the same Ruby symbol with matching " \
           "js_identifier (one js_identifier per emitted export is the design intent)" do
          actions.register(:categories, kind: :action, controller: posts_controller)
          queries.register(:categories, kind: :query, controller: cats_controller)
          expect { described_class.functions_payload(actions, queries) }
            .to raise_error(Ruact::ConfigurationError, /server-function naming collision/)
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

        it "rewrites the file when the on-disk snapshot has a different version " \
           "(Chunk1 Major 2026-05-13 — version mismatch must not be treated as unchanged)" do
          File.write(path, JSON.pretty_generate(version: 99, generated_at: "2020-01-01T00:00:00Z", functions: []))
          result = described_class.generate!(
            action_registry: actions, query_registry: queries, path: path, now: frozen_time
          )
          expect(result).to be(true)
          expect(JSON.parse(File.read(path))["version"]).to eq(1)
        end
      end
    end
  end
end
