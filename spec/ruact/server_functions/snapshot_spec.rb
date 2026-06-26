# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

module Ruact
  module ServerFunctions
    RSpec.describe Snapshot, :story_9_3 do
      let(:frozen_time) { Time.utc(2026, 5, 13, 12, 34, 56) }
      let(:entries) do
        [
          { "js_identifier" => "createPost", "kind" => "action", "http_method" => "POST",
            "path" => "/posts", "segments" => [], "controller" => "posts", "action" => "create" }
        ]
      end

      describe ".dump_v2" do
        it "wraps entries in a version-2 snapshot Hash" do
          snap = described_class.dump_v2(entries, now: frozen_time)
          expect(snap[:version]).to eq(2)
          expect(snap[:generated_at]).to eq(frozen_time.iso8601)
          expect(snap[:functions]).to eq(entries)
        end
      end

      describe ".generate_v2! (write-if-changed)" do
        around do |example|
          Dir.mktmpdir do |dir|
            @tmpdir = dir
            example.run
          end
        end

        let(:path) { File.join(@tmpdir, "server-functions.json") }

        it "writes a version-2 bridge on first call" do
          expect(described_class.generate_v2!(entries: entries, path: path, now: frozen_time)).to be(true)
          parsed = JSON.parse(File.read(path))
          expect(parsed.fetch("version")).to eq(2)
          expect(parsed.fetch("functions").first.fetch("js_identifier")).to eq("createPost")
        end

        it "short-circuits when entries are unchanged (no timestamp churn)" do
          described_class.generate_v2!(entries: entries, path: path, now: frozen_time)
          expect(described_class.generate_v2!(entries: entries, path: path, now: Time.now.utc)).to be(false)
        end

        it "rewrites when entries change" do
          described_class.generate_v2!(entries: entries, path: path, now: frozen_time)
          more = entries + [{ "js_identifier" => "destroyPost", "kind" => "action",
                              "http_method" => "DELETE", "path" => "/posts/:id",
                              "segments" => ["id"], "controller" => "posts", "action" => "destroy" }]
          expect(described_class.generate_v2!(entries: more, path: path, now: frozen_time)).to be(true)
        end

        it "creates the parent directory if missing" do
          nested = File.join(@tmpdir, "deep", "nested", "server-functions.json")
          expect(described_class.generate_v2!(entries: entries, path: nested, now: frozen_time)).to be(true)
          expect(File.exist?(nested)).to be(true)
        end

        it "recovers from a corrupted existing file by overwriting it" do
          File.write(path, "{ not json")
          expect(described_class.generate_v2!(entries: entries, path: path, now: frozen_time)).to be(true)
          expect(JSON.parse(File.read(path)).fetch("version")).to eq(2)
        end

        # Story 13.4 — the new typed-query metadata must survive the JSON
        # round-trip unchanged AND keep the file byte-stable (no churn on a
        # second pass with identical entries).
        context "with typed-query params metadata (Story 13.4)", :story_13_4 do
          let(:query_entries) do
            [
              { "js_identifier" => "searchUsers", "kind" => "query", "http_method" => "GET",
                "path" => "/q/searchUsers", "segments" => [], "accepts_params" => true,
                "params" => [{ "name" => "term", "required" => true },
                             { "name" => "limit", "required" => false }],
                "params_rest" => false, "controller" => "CatalogQuery", "action" => "search_users" }
            ]
          end

          it "round-trips the params metadata unchanged" do
            described_class.generate_v2!(entries: query_entries, path: path, now: frozen_time)
            parsed = JSON.parse(File.read(path))
            expect(parsed.fetch("functions")).to eq(query_entries)
          end

          it "is byte-stable: a second pass with identical entries writes nothing" do
            described_class.generate_v2!(entries: query_entries, path: path, now: frozen_time)
            expect(described_class.generate_v2!(entries: query_entries, path: path, now: Time.now.utc)).to be(false)
          end
        end
      end
    end
  end
end
