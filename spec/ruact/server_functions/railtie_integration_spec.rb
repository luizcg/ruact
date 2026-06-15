# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "action_controller"

# Spec_helper's rails_stub defines Rails; the railtie was not auto-required
# because Rails was not yet defined when ruact.rb evaluated `require_relative
# "ruact/railtie" if defined?(Rails)`. Load it explicitly (mirrors
# spec/ruact/railtie_spec.rb).
require "ruact/railtie"
require "ruact/controller"
require "ruact/server"
require "ruact/routing"
require "ruact/query"

# Story 9.9 — the route-driven (v2) codegen is the sole writer of the real
# bridge. `Railtie.write_server_functions_snapshot!` is the entry point wired
# into `config.to_prepare`; it forces the route table to load, then delegates to
# `ServerFunctions.write_v2_snapshot!`, which writes the v2 snapshot to the REAL
# bridge (`tmp/cache/ruact/server-functions.json`).
module Ruact
  module ServerFunctions
    RSpec.describe "Ruact::Railtie.write_server_functions_snapshot! (Story 9.9)", :story_9_9 do
      before do
        stub_const("WrapperDemoPostsController", Class.new(ActionController::Base) { include Ruact::Server })
      end

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

      # Drives the wrapper by stubbing Rails.application with a routes set + a
      # no-op routes_reloader (the cold-boot ordering fold-in).
      def stub_application(routes)
        reloader = Object.new
        def reloader.execute_unless_loaded; end
        app = Object.new
        app.define_singleton_method(:routes) { routes }
        app.define_singleton_method(:routes_reloader) { reloader }
        allow(Rails).to receive(:application).and_return(app)
      end

      def route_set
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw { resources :wrapper_demo_posts, only: %i[create update destroy] }
        rs
      end

      it "writes the v2 JSON to the REAL bridge (tmp/cache/ruact/server-functions.json)" do
        stub_application(route_set)
        entries = Ruact::Railtie.write_server_functions_snapshot!
        expect(entries.map { |e| e["js_identifier"] })
          .to match_array(%w[createWrapperDemoPost updateWrapperDemoPost destroyWrapperDemoPost])
        expect(File).to exist(path)
        expect(JSON.parse(File.read(path)).fetch("version")).to eq(2)
      end

      it "writes an empty `functions: []` array when no routes are exposed" do
        empty = ActionDispatch::Routing::RouteSet.new
        empty.draw { get "/health", to: "health#show" }
        stub_application(empty)
        Ruact::Railtie.write_server_functions_snapshot!
        expect(JSON.parse(File.read(path)).fetch("functions")).to eq([])
      end

      it "forces the route table to load before reading it (cold-boot ordering fold-in)" do
        reloader = Object.new
        called = false
        reloader.define_singleton_method(:execute_unless_loaded) { called = true }
        routes = route_set
        app = Object.new
        app.define_singleton_method(:routes) { routes }
        app.define_singleton_method(:routes_reloader) { reloader }
        allow(Rails).to receive(:application).and_return(app)
        Ruact::Railtie.write_server_functions_snapshot!
        expect(called).to be(true)
      end
    end

    RSpec.describe "Ruact::ServerFunctions.write_v2_snapshot! (Story 9.3)", :story_9_3 do
      # A real Ruact::Server host so RouteSource's default constant-resolving
      # host predicate recognizes it; stub_const (not a literal class) keeps the
      # file single-definition and the constant scoped to the example.
      before do
        stub_const("V2DemoPostsController", Class.new(ActionController::Base) { include Ruact::Server })
      end

      around do |example|
        Dir.mktmpdir { |dir| @tmpdir = dir and example.run }
      end

      def route_set
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw { resources :v2_demo_posts, only: %i[create update destroy] }
        rs
      end

      def write!(logger: nil)
        Ruact::ServerFunctions.write_v2_snapshot!(
          route_set: route_set, root: Pathname.new(@tmpdir), logger: logger
        )
      end

      # Story 9.9 — the v2 codegen writes the REAL bridge (the `.next` parallel
      # target was demolished).
      let(:real_json) { File.join(@tmpdir, "tmp/cache/ruact/server-functions.json") }
      let(:real_ts)   { File.join(@tmpdir, "app/javascript/.ruact/server-functions.ts") }

      it "writes the v2 bridge + TS to the REAL target" do
        entries = write!

        expect(entries.map { |e| e["js_identifier"] })
          .to match_array(%w[createV2DemoPost updateV2DemoPost destroyV2DemoPost])
        expect(File).to exist(real_json)
        expect(File).to exist(real_ts)
        expect(JSON.parse(File.read(real_json)).fetch("version")).to eq(2)
      end

      it "renders _makeServerFunction calls targeting real routes into the TS" do
        write!
        ts = File.read(real_ts)
        expect(ts).to include('import { _makeServerFunction } from "ruact/server-functions-runtime";')
        expect(ts).to include('_makeServerFunction({ method: "POST", path: "/v2_demo_posts", segments: [] });')
        expect(ts).to include('_makeServerFunction({ method: "PATCH", path: "/v2_demo_posts/:id", segments: ["id"] });')
      end

      it "is byte-stable across calls on an unchanged route table (no churn)" do
        write!
        first = File.read(real_ts)
        write!
        expect(File.read(real_ts)).to eq(first)
      end

      it "logs the exposed function names (AC2 — transparency over silence)" do
        logger = instance_double(Logger, info: nil)
        write!(logger: logger)
        expect(logger).to have_received(:info).with(/\[ruact\] codegen: exposing .*createV2DemoPost/)
      end
    end

    RSpec.describe "Ruact::ServerFunctions.write_v2_snapshot! — queries (Story 9.5)", :story_9_5 do
      around do |example|
        Dir.mktmpdir { |dir| @tmpdir = dir and example.run }
      end

      before do
        stub_const("V2QueryParentController", Class.new(ActionController::Base))
        Ruact.configure { |c| c.query_parent_controller = "V2QueryParentController" }
        stub_const("V2CatalogQuery", Class.new(Ruact::Query) do
          def categories; end
          def search(term:); end
        end)
      end

      def route_set
        route_set = ActionDispatch::Routing::RouteSet.new
        route_set.draw { ruact_queries V2CatalogQuery }
        route_set
      end

      def write!(routes = route_set)
        Ruact::ServerFunctions.write_v2_snapshot!(route_set: routes, root: Pathname.new(@tmpdir))
      end

      let(:real_ts) { File.join(@tmpdir, "app/javascript/.ruact/server-functions.ts") }

      it "emits query entries (route-truth) merged into the v2 snapshot" do
        entries = write!
        expect(entries.map { |e| e["js_identifier"] }).to match_array(%w[categories search])
        expect(entries).to all(include("kind" => "query", "http_method" => "GET"))
      end

      it "renders _makeQuery refs + the useQuery re-export into the TS" do
        write!
        ts = File.read(real_ts)
        expect(ts).to include('import { _makeQuery } from "ruact/server-functions-runtime";')
        expect(ts).to include('_makeQuery({ path: "/q/categories", kind: "query" });')
        expect(ts).to include("export const categories: () => Promise<unknown> =")
        expect(ts).to include("export const search: (params: Record<string, unknown>) => Promise<unknown> =")
        expect(ts).to include('export { useQuery } from "ruact/server-functions-runtime";')
      end

      it "raises a route×query collision when an action and a query share a js_identifier" do
        stub_const("CategoriesController", Class.new(ActionController::Base) { include Ruact::Server })
        stub_const("CollideQuery", Class.new(Ruact::Query) { def categories; end })
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw do
          post "categories", to: "categories#categories"
          ruact_queries CollideQuery
        end
        CategoriesController.define_singleton_method(:__ruact_function_name_overrides) do
          { "categories" => "categories" }
        end
        expect { Ruact::ServerFunctions.write_v2_snapshot!(route_set: rs, root: Pathname.new(@tmpdir)) }
          .to raise_error(Ruact::ConfigurationError, /both map to JS identifier "categories".*ruact_function_name/m)
      end
    end
  end
end
