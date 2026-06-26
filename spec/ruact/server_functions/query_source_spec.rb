# frozen_string_literal: true

require "spec_helper"
require "ruact/server_functions"
require "ruact/server_functions/query_source"

module Ruact
  module ServerFunctions
    # Plain query classes — only `instance_method(...).parameters` (kwargs
    # presence) and `.name` (collision origin) are read. Defined at module
    # level so they are not example-group-leaky constants.
    class CatalogQ
      def categories; end

      def search_users(term:, limit: 10); end
    end

    class PeopleQ
      def search_users(term:); end
    end

    # Story 13.4 — kwarg shapes exercising the per-param metadata derivation:
    # a `**keyrest` (anonymous + named), and a positional that must be ignored.
    class ParamShapesQ
      def with_rest(scope:, **opts); end

      def rest_only(**opts); end

      def positional_ignored(id, query:); end
    end

    # Story 9.5 — query introspection: the drawn route table (filtered to the
    # generated query dispatch controllers) → v2 query entries. Pure: route set
    # and the query-class resolver are injected, so the derivation is testable
    # with no Rails boot and no controllers (a fake route set + plain query
    # classes).
    RSpec.describe QuerySource, :story_9_5 do
      # Minimal route double exposing the surface QuerySource reads:
      # `defaults[:controller]`, `defaults[:action]`, `path.spec.to_s`.
      def query_route(controller, action, path)
        spec = Object.new
        spec.define_singleton_method(:to_s) { "#{path}(.:format)" }
        path_obj = Object.new
        path_obj.define_singleton_method(:spec) { spec }
        route = Object.new
        route.define_singleton_method(:defaults) { { controller: controller, action: action } }
        route.define_singleton_method(:path) { path_obj }
        route
      end

      def route_set(routes)
        rs = Object.new
        rs.define_singleton_method(:routes) { routes }
        rs
      end

      let(:prefix) { QuerySource::QUERY_CONTROLLER_PREFIX }

      def resolver(map)
        ->(controller) { map[controller] }
      end

      describe ".collect" do
        it "emits one query entry per mounted query route (route-truth)" do
          rs = route_set([
                           query_route("#{prefix}catalog_q", "categories", "/q/categories"),
                           query_route("#{prefix}catalog_q", "search_users", "/q/searchUsers")
                         ])
          entries = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ))

          expect(entries.map { |e| e["js_identifier"] }).to eq(%w[categories searchUsers])
          expect(entries).to all(include("kind" => "query", "http_method" => "GET", "segments" => []))
        end

        it "derives jsId via NameBridge and carries the clean path" do
          rs = route_set([query_route("#{prefix}catalog_q", "search_users", "/q/searchUsers")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ)).first
          expect(entry["js_identifier"]).to eq("searchUsers")
          expect(entry["path"]).to eq("/q/searchUsers")
          expect(entry["controller"]).to eq("Ruact::ServerFunctions::CatalogQ")
          expect(entry["action"]).to eq("search_users")
        end

        it "flags accepts_params true when the method declares kwargs, false otherwise" do
          rs = route_set([
                           query_route("#{prefix}catalog_q", "categories", "/q/categories"),
                           query_route("#{prefix}catalog_q", "search_users", "/q/searchUsers")
                         ])
          entries = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ))
          by_id = entries.to_h { |e| [e["js_identifier"], e] }
          expect(by_id["categories"]["accepts_params"]).to be(false)
          expect(by_id["searchUsers"]["accepts_params"]).to be(true)
        end

        it "derives per-kwarg params metadata (name + required/optional, declaration order)", :story_13_4 do
          rs = route_set([query_route("#{prefix}catalog_q", "search_users", "/q/searchUsers")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ)).first
          expect(entry["params"]).to eq([
                                          { "name" => "term", "required" => true },
                                          { "name" => "limit", "required" => false }
                                        ])
          expect(entry["params_rest"]).to be(false)
        end

        it "emits empty params + accepts_params false for a no-kwargs query", :story_13_4 do
          rs = route_set([query_route("#{prefix}catalog_q", "categories", "/q/categories")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ)).first
          expect(entry["params"]).to eq([])
          expect(entry["params_rest"]).to be(false)
          expect(entry["accepts_params"]).to be(false)
        end

        it "flags params_rest for a `**keyrest` and still carries the named keys", :story_13_4 do
          rs = route_set([query_route("#{prefix}params_q", "with_rest", "/q/withRest")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}params_q" => ParamShapesQ)).first
          expect(entry["params"]).to eq([{ "name" => "scope", "required" => true }])
          expect(entry["params_rest"]).to be(true)
          expect(entry["accepts_params"]).to be(true)
        end

        it "treats a `**keyrest`-only query as accepts_params (rest, no named keys)", :story_13_4 do
          rs = route_set([query_route("#{prefix}params_q", "rest_only", "/q/restOnly")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}params_q" => ParamShapesQ)).first
          expect(entry["params"]).to eq([])
          expect(entry["params_rest"]).to be(true)
          expect(entry["accepts_params"]).to be(true)
        end

        it "ignores positional params (only kwargs are FR88 query params)", :story_13_4 do
          rs = route_set([query_route("#{prefix}params_q", "positional_ignored", "/q/positionalIgnored")])
          entry = described_class.collect(rs, query_class_for: resolver("#{prefix}params_q" => ParamShapesQ)).first
          expect(entry["params"]).to eq([{ "name" => "query", "required" => true }])
          expect(entry["params_rest"]).to be(false)
        end

        it "ignores non-query routes (controller not under the dispatch namespace)" do
          rs = route_set([
                           query_route("posts", "create", "/posts"),
                           query_route("#{prefix}catalog_q", "categories", "/q/categories")
                         ])
          entries = described_class.collect(rs, query_class_for: resolver("#{prefix}catalog_q" => CatalogQ))
          expect(entries.map { |e| e["js_identifier"] }).to eq(%w[categories])
        end

        it "skips a query route whose class cannot be resolved (nil resolver result)" do
          rs = route_set([query_route("#{prefix}gone_q", "categories", "/q/categories")])
          expect(described_class.collect(rs, query_class_for: resolver({}))).to eq([])
        end

        it "raises a query×query collision naming both origins" do
          rs = route_set([
                           query_route("#{prefix}catalog_q", "search_users", "/q/searchUsers"),
                           query_route("#{prefix}people_q", "search_users", "/q/searchUsers")
                         ])
          map = { "#{prefix}catalog_q" => CatalogQ, "#{prefix}people_q" => PeopleQ }
          expect { described_class.collect(rs, query_class_for: resolver(map)) }
            .to raise_error(Ruact::ConfigurationError, /CatalogQ#search_users and .*PeopleQ#search_users/m)
        end
      end
    end

    # Story 9.5 (Task 2) — the merged JS namespace (route entries + query
    # entries share it). The route×query side is detected at the codegen
    # combine point.
    RSpec.describe ".detect_merged_namespace_collisions!", :story_9_5 do
      def action_entry(js_id, controller, action)
        { "js_identifier" => js_id, "kind" => "action", "controller" => controller, "action" => action }
      end

      def query_entry(js_id, controller, action)
        { "js_identifier" => js_id, "kind" => "query", "controller" => controller, "action" => action }
      end

      it "raises on a route×query collision naming both origins + the rename escape hatch" do
        entries = [
          action_entry("categories", "posts", "categories"),
          query_entry("categories", "CatalogQuery", "categories")
        ]
        expect { ServerFunctions.detect_merged_namespace_collisions!(entries) }
          .to raise_error(Ruact::ConfigurationError,
                          /posts#categories and CatalogQuery#categories.*ruact_function_name/m)
      end

      it "does not raise when the rename makes the identifiers distinct" do
        entries = [
          action_entry("listCategories", "posts", "categories"), # renamed via ruact_function_name
          query_entry("categories", "CatalogQuery", "categories")
        ]
        expect { ServerFunctions.detect_merged_namespace_collisions!(entries) }.not_to raise_error
      end
    end
  end
end
