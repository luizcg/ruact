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

      let(:next_json) { File.join(@tmpdir, "tmp/cache/ruact/server-functions.next.json") }
      let(:next_ts)   { File.join(@tmpdir, "app/javascript/.ruact/server-functions.next.ts") }
      let(:real_json) { File.join(@tmpdir, "tmp/cache/ruact/server-functions.json") }

      it "writes the v2 bridge + TS to the PARALLEL .next target (not the real file)" do
        entries = write!

        expect(entries.map { |e| e["js_identifier"] })
          .to match_array(%w[createV2DemoPost updateV2DemoPost destroyV2DemoPost])
        expect(File).to exist(next_json)
        expect(File).to exist(next_ts)
        # AC5/AC6 — the v1 real bridge is NOT written by the v2 path.
        expect(File).not_to exist(real_json)
        expect(JSON.parse(File.read(next_json)).fetch("version")).to eq(2)
      end

      it "renders _makeServerFunction calls targeting real routes into the .next TS" do
        write!
        ts = File.read(next_ts)
        expect(ts).to include('import { _makeServerFunction } from "ruact/server-functions-runtime";')
        expect(ts).to include('_makeServerFunction({ method: "POST", path: "/v2_demo_posts", segments: [] });')
        expect(ts).to include('_makeServerFunction({ method: "PATCH", path: "/v2_demo_posts/:id", segments: ["id"] });')
      end

      it "is byte-stable across calls on an unchanged route table (no churn)" do
        write!
        first = File.read(next_ts)
        write!
        expect(File.read(next_ts)).to eq(first)
      end

      it "logs the exposed function names (AC2 — transparency over silence)" do
        logger = instance_double(Logger, info: nil)
        write!(logger: logger)
        expect(logger).to have_received(:info).with(/\[ruact\] codegen: exposing .*createV2DemoPost/)
      end
    end

    RSpec.describe "Ruact::ServerFunctions.write_v2_snapshot! — queries (Story 9.5)", :story_9_5 do
      # `ruact_queries` + query dispatch live behind these requires (loaded
      # explicitly here as the railtie would at boot).
      require "ruact/routing"
      require "ruact/query"

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

      let(:next_ts) { File.join(@tmpdir, "app/javascript/.ruact/server-functions.next.ts") }

      it "emits query entries (route-truth) merged into the v2 snapshot" do
        entries = write!
        expect(entries.map { |e| e["js_identifier"] }).to match_array(%w[categories search])
        expect(entries).to all(include("kind" => "query", "http_method" => "GET"))
      end

      it "renders _makeQuery refs + the useQuery re-export into the .next TS" do
        write!
        ts = File.read(next_ts)
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
          # POST /categories#create would derive js_identifier "createCategory" — to
          # force a clash, use a custom collection route named to collide head-on.
          post "categories", to: "categories#categories"
          ruact_queries CollideQuery
        end
        # Rename the action's js_identifier to exactly "categories" so it collides
        # with the query method.
        CategoriesController.define_singleton_method(:__ruact_function_name_overrides) do
          { "categories" => "categories" }
        end
        expect { Ruact::ServerFunctions.write_v2_snapshot!(route_set: rs, root: Pathname.new(@tmpdir)) }
          .to raise_error(Ruact::ConfigurationError, /both map to JS identifier "categories".*ruact_function_name/m)
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

    # Story 8.1 Re-run-6/8 — force_load_controllers! now walks Rails::Engine
    # subclasses so engine-owned `ruact_action` declarations populate the
    # registry at boot (not on first request to the engine controller).
    # The regression target: a mounted engine that declares its own controller
    # with `ruact_action :engine_action` must be visible to the snapshot
    # writer + endpoint dispatcher BEFORE any HTTP traffic.
    RSpec.describe "Ruact::Railtie.force_load_controllers! engine scanning (Story 8.1)", :story_8_1 do
      before do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!

        # In a real Rails boot, `require_dependency` is added to `Object` by
        # `ActiveSupport::Dependencies.hook!` before `config.to_prepare`
        # fires. The minimal spec-env setup (rails_stub + action_controller
        # core) does not invoke the hook, so we stub the call directly to
        # delegate to plain `load(file)` — which is sufficient to exercise
        # the engine-scanning branch without dragging the full dependencies
        # subsystem into the suite.
        allow(Ruact::Railtie).to receive(:force_load_dir).and_wrap_original do |_original, dir|
          files = Dir.glob("#{dir}/**/*_controller.rb")
          files.each { |file| load(file) }
          files.length
        end
      end

      it "loads ruact_action declarations from a mounted Rails::Engine's app/controllers " \
         "(re-run-6 #4 / re-run-8 #2 — engine-owned controllers must populate the registry at boot)" do
        Dir.mktmpdir do |engine_dir|
          # Build the engine's controller file on disk. The file's body
          # declares a real `ruact_action` so populating the registry is
          # observable (no mocks of the macro itself).
          controllers_dir = File.join(engine_dir, "app/controllers")
          FileUtils.mkdir_p(controllers_dir)
          controller_path = File.join(controllers_dir, "engine_demo_controller.rb")
          File.write(controller_path, <<~RUBY)
            # frozen_string_literal: true

            class EngineDemoController < ActionController::Base
              include Ruact::Controller

              ruact_action(:engine_only_action) { |_params| "from-engine" }
            end
          RUBY

          # Build a real Rails::Engine subclass whose paths["app/controllers"]
          # points at the on-disk controllers directory. `Engine#paths` is
          # automatically populated by Rails.
          fake_engine = Class.new(Rails::Engine) do
            isolate_namespace Module.new
            config.paths["app/controllers"] = controllers_dir
          end

          # Stub Rails::Engine.subclasses to return JUST our fake engine — the
          # host app's own engine class is filtered out inside
          # force_load_controllers! by an explicit `engine_class ==
          # Rails.application.class` skip.
          allow(Rails::Engine).to receive(:subclasses).and_return([fake_engine])

          expect { Ruact::Railtie.force_load_controllers! }.not_to raise_error
          expect(Ruact.action_registry.entries[:engine_only_action]).not_to be_nil
          expect(Ruact.action_registry.entries[:engine_only_action].controller).to be(EngineDemoController)
        end
      ensure
        # `EngineDemoController` is loaded via `require_dependency` against an
        # absolute on-disk path; remove the constant so re-runs of the spec
        # don't trip the macro's "method already defined" guard.
        Object.send(:remove_const, :EngineDemoController) if defined?(EngineDemoController)
      end

      it "skips the host application's own Rails::Engine subclass " \
         "(avoids double-loading app/controllers already covered by the Rails.application branch)" do
        # Rails.application.class IS a Rails::Engine subclass; force_load_controllers!
        # iterates the host app FIRST via the application branch, then skips it
        # explicitly in the engine branch. Confirm that filtering happens.
        host_class = Rails.application.class
        allow(Rails::Engine).to receive(:subclasses).and_return([host_class])

        # We expect ZERO additional load operations from the engine branch
        # because the only subclass is the host app itself.
        expect(Ruact::Railtie).not_to receive(:safe_engine_instance)

        expect { Ruact::Railtie.force_load_controllers! }.not_to raise_error
      end

      it "swallows a misconfigured engine (engine_class.instance raising) " \
         "via safe_engine_instance so a single broken engine cannot block boot" do
        bad_engine = Class.new(Rails::Engine)
        allow(bad_engine).to receive(:instance).and_raise(StandardError, "engine boot failed")
        allow(Rails::Engine).to receive(:subclasses).and_return([bad_engine])

        # Must not propagate; force_load_controllers! returns normally.
        expect { Ruact::Railtie.force_load_controllers! }.not_to raise_error
      end
    end

    # Story 8.3 — force_load_server_function_hosts! ALSO walks
    # `app/server_actions/**/*.rb` so standalone modules register at boot
    # alongside controller-hosted actions. Follows the Story 8.1 fake-engine
    # pattern to bypass Rails.application's sticky root memoization.
    RSpec.describe "Ruact::Railtie.force_load_server_function_hosts! " \
                   "app/server_actions/ scanning (Story 8.3)", :story_8_3 do
      before do
        Ruact.action_registry.clear!
        Ruact.query_registry.clear!

        # Same stub as the Story 8.1 engine-scanning describe — substitutes
        # `require_dependency` (unavailable in the minimal spec env) with
        # plain `load`. Accepts both `dir` (positional) and `glob:` (kwarg).
        allow(Ruact::Railtie).to receive(:force_load_dir).and_wrap_original do |_original, dir, glob: "**/*_controller.rb"|
          files = Dir.glob("#{dir}/#{glob}")
          files.each { |file| load(file) }
          files.length
        end
      end

      it "loads ruact_action declarations from app/server_actions/ at boot " \
         "(Pitfall #7 — standalone modules must register before the snapshot writer runs)" do
        Dir.mktmpdir do |engine_dir|
          server_actions_dir = File.join(engine_dir, "app/server_actions")
          FileUtils.mkdir_p(server_actions_dir)
          module_path = File.join(server_actions_dir, "standalone_railtie_demo.rb")
          File.write(module_path, <<~RUBY)
            # frozen_string_literal: true

            module StandaloneRailtieDemo
              extend Ruact::ServerAction

              ruact_action(:standalone_railtie_demo) { |_p| "from-standalone" }
            end
          RUBY

          fake_engine = Class.new(Rails::Engine) do
            isolate_namespace Module.new
            # Register the path explicitly so `server_actions_paths_for`
            # finds it via the Rails paths enumerator.
            config.paths.add "app/server_actions", with: server_actions_dir
          end

          # Stub Rails::Engine.subclasses to expose ONLY the fake engine —
          # the host app's own controllers/server_actions are filtered out
          # by the engine_class == Rails.application.class skip inside
          # force_load_server_function_hosts!.
          allow(Rails::Engine).to receive(:subclasses).and_return([fake_engine])

          expect { Ruact::Railtie.force_load_server_function_hosts! }.not_to raise_error

          entry = Ruact.action_registry.entries[:standalone_railtie_demo]
          expect(entry).not_to be_nil
          expect(entry.controller).to be(StandaloneRailtieDemo)
          expect(entry.controller).to be_a(Module)
          expect(entry.controller).not_to be_a(Class)
        end
      ensure
        Object.send(:remove_const, :StandaloneRailtieDemo) if defined?(StandaloneRailtieDemo)
      end

      it "silently no-ops when no engine has an app/server_actions/ directory " \
         "(typical for apps that only use controller-hosted actions)" do
        allow(Rails::Engine).to receive(:subclasses).and_return([])
        expect { Ruact::Railtie.force_load_server_function_hosts! }.not_to raise_error
      end

      it "back-compat: the old `force_load_controllers!` name aliases to the new method" do
        expect(Ruact::Railtie.method(:force_load_controllers!).original_name)
          .to eq(:force_load_server_function_hosts!)
      end
    end
  end
end
