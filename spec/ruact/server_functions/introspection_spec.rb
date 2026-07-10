# frozen_string_literal: true

require "spec_helper"
require "active_support/all"
require "action_dispatch"
require "ruact/server_functions"

module Ruact
  module ServerFunctions
    # Plain query class — only `instance_method(...).parameters` (kwargs) and
    # `.name` (collision origin) are read; no Rails boot needed. Defined at module
    # level (mirrors query_source_spec) so it is not an example-group-leaky
    # constant.
    class CatalogIntrospectQ
      def categories; end

      def search_users(term:, limit: 10); end
    end

    # Story 15.3 (FR107) — `ruact:routes --json` introspection. Exercised through
    # a REAL RouteSet carrying both a mutation action and mounted query routes,
    # with the host/query resolvers injected (no controller boot), so the document
    # is proven byte-derived from RouteSource + QuerySource (the same single
    # source of truth codegen consumes) and side-effect-free.
    RSpec.describe Introspection, :story_15_3 do
      let(:query_prefix) { QuerySource::QUERY_CONTROLLER_PREFIX }

      # A real RouteSet with a mutation action (createPost, updatePost) AND two
      # mounted query GET routes under the query dispatch controller prefix.
      def combined_route_set
        prefix = query_prefix
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw do
          resources :posts, only: %i[create update]
          get "/q/categories", to: "#{prefix}catalog_introspect_q#categories"
          get "/q/search_users", to: "#{prefix}catalog_introspect_q#search_users"
        end
        rs
      end

      def as_json(route_set)
        described_class.as_json(
          route_set: route_set,
          host_predicate: ->(_controller) { true },
          query_class_for: lambda { |controller|
            controller.start_with?(query_prefix) ? CatalogIntrospectQ : nil
          }
        )
      end

      describe ".as_json" do
        subject(:document) { as_json(combined_route_set) }

        it "gates the document with the EXPERIMENTAL schema_version (0)", :aggregate_failures do
          expect(document["schema_version"]).to eq(0)
          expect(document["schema_version"]).to eq(described_class::SCHEMA_VERSION)
        end

        it "round-trips through JSON.parse" do
          expect(JSON.parse(JSON.generate(document))).to eq(document)
        end

        it "reports BOTH action and query accessors sorted by name", :aggregate_failures do
          names = document["accessors"].map { |a| a["accessor"] }
          expect(names).to include("createPost", "updatePost", "categories", "searchUsers")
          expect(names).to eq(names.sort)
        end

        it "shapes an action with its required path segments as declared params", :aggregate_failures do
          update = document["accessors"].find { |a| a["accessor"] == "updatePost" }
          expect(update["kind"]).to eq("action")
          expect(update["verb"]).to eq("PATCH")
          expect(update["path"]).to eq("/posts/:id")
          expect(update["segments"]).to eq(["id"])
          expect(update["params"]).to eq([{ "name" => "id", "required" => true }])
        end

        it "shapes a query with its declared kwargs as params (Story 13.4)", :aggregate_failures do
          search = document["accessors"].find { |a| a["accessor"] == "searchUsers" }
          expect(search["kind"]).to eq("query")
          expect(search["verb"]).to eq("GET")
          expect(search["path"]).to eq("/q/search_users")
          expect(search["segments"]).to eq([])
          expect(search["params"]).to eq(
            [{ "name" => "term", "required" => true }, { "name" => "limit", "required" => false }]
          )
        end

        it "carries exactly the AC2 keys per accessor" do
          document["accessors"].each do |accessor|
            expect(accessor.keys).to contain_exactly("accessor", "kind", "verb", "path", "segments", "params")
          end
        end

        it "does NOT include a per-accessor component-contract link (D3 = report accessors faithfully)" do
          document["accessors"].each do |accessor|
            expect(accessor).not_to have_key("contract")
            expect(accessor).not_to have_key("has_contract")
            expect(accessor).not_to have_key("contract_exists")
          end
        end
      end

      describe "side-effect-free (AC2 / AC4d — writes NO bridge or TS)" do
        it "never writes the codegen bridge / TS module", :aggregate_failures do
          allow(SnapshotWriter).to receive(:write_if_changed!)
          allow(Snapshot).to receive(:generate_v2!)
          allow(Codegen).to receive(:generate_ts!)
          allow(File).to receive(:write).and_call_original

          as_json(combined_route_set)

          expect(SnapshotWriter).not_to have_received(:write_if_changed!)
          expect(Snapshot).not_to have_received(:generate_v2!)
          expect(Codegen).not_to have_received(:generate_ts!)
          expect(File).not_to have_received(:write)
        end
      end

      describe "single source of truth (AC2)" do
        it "is byte-derived from ServerFunctions.introspect (same collectors as codegen)" do
          # Both introspection and write_v2_snapshot! flow through .introspect;
          # the document's accessors mirror those entries' identifiers exactly.
          entries = ServerFunctions.introspect(
            route_set: combined_route_set,
            host_predicate: ->(_c) { true },
            query_class_for: ->(c) { c.start_with?(query_prefix) ? CatalogIntrospectQ : nil }
          )
          expect(as_json(combined_route_set)["accessors"].map { |a| a["accessor"] })
            .to eq(entries.map { |e| e["js_identifier"] })
        end
      end
    end
  end
end
