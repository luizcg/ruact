# frozen_string_literal: true

require "spec_helper"

module Ruact
  module ServerFunctions
    RSpec.describe Registry, :story_8_0a do
      subject(:registry) { described_class.new }

      let(:posts_controller) do
        Class.new { def self.name = "PostsController" }
      end

      let(:bar_controller) do
        Class.new { def self.name = "BarController" }
      end

      describe "#register (Story 8.0a)" do
        it "stores a single entry keyed by its Ruby symbol", :aggregate_failures do
          entry = registry.register(:create_post, kind: :action, controller: posts_controller)

          expect(entry).to be_a(RegistryEntry)
          expect(entry.ruby_symbol).to eq(:create_post)
          expect(entry.js_identifier).to eq("createPost")
          expect(entry.kind).to eq(:action)
          expect(entry.controller).to eq(posts_controller)
          expect(registry.entries.keys).to eq([:create_post])
        end

        it "captures the implementation block verbatim for downstream invocation" do
          block = -> { :pong }
          entry = registry.register(:demo_ping, kind: :action, controller: posts_controller, &block)
          expect(entry.block).to be(block)
        end

        it "allows registering an action and a query with the same symbol in separate registries" do
          actions = described_class.new
          queries = described_class.new
          actions.register(:create_post, kind: :action, controller: posts_controller)
          queries.register(:create_post, kind: :query, controller: posts_controller)
          expect(actions.entries.keys).to eq([:create_post])
          expect(queries.entries.keys).to eq([:create_post])
        end

        it "raises Ruact::ConfigurationError for SCREAMING_SNAKE symbols (Story 8.0a)" do
          expect { registry.register(:RECALCULATE, kind: :action, controller: posts_controller) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to include(":RECALCULATE")
            end
        end

        it "raises Ruact::ConfigurationError on JS-identifier collision and names both " \
           "Ruby symbols and both controllers (Story 8.0a)", :aggregate_failures do
          registry.register(:foo_bar, kind: :action, controller: posts_controller)
          expect { registry.register(:foo__bar, kind: :action, controller: bar_controller) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to include(":foo_bar")
              expect(error.message).to include(":foo__bar")
              expect(error.message).to include("PostsController")
              expect(error.message).to include("BarController")
              expect(error.message).to include('"fooBar"')
            end
        end

        it "allows re-registering the same Ruby symbol (replace semantics, dev reload)" do
          registry.register(:create_post, kind: :action, controller: posts_controller)
          expect do
            registry.register(:create_post, kind: :action, controller: posts_controller)
          end.not_to raise_error
          expect(registry.size).to eq(1)
        end

        it "tolerates a nil controller (Rails-console registration path)" do
          expect { registry.register(:create_post, kind: :action) }.not_to raise_error
        end

        it "rejects kinds other than :action / :query (Chunk1 Major 2026-05-13)" do
          expect { registry.register(:create_post, kind: :wat, controller: posts_controller) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to include(":create_post")
              expect(error.message).to include("PostsController")
              expect(error.message).to include(":wat")
              expect(error.message).to include("[:action, :query]")
            end
        end

        it "wraps NameBridge symbol-shape failures with AC7 'invalid server-function " \
           "symbol :SYMBOL in CONTROLLER' framing (Re-run patch m5)" do
          expect { registry.register(:RECALCULATE, kind: :action, controller: posts_controller) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to start_with("invalid server-function symbol :RECALCULATE in PostsController")
            end
        end
      end

      describe "#entries (Story 8.0a)" do
        it "returns a frozen snapshot independent of subsequent mutations" do
          registry.register(:create_post, kind: :action, controller: posts_controller)
          snapshot = registry.entries
          expect(snapshot).to be_frozen
          registry.register(:list_posts, kind: :query, controller: posts_controller)
          expect(snapshot.keys).to eq([:create_post])
        end
      end

      describe "#clear! (Story 8.0a)" do
        it "wipes all entries and returns self" do
          registry.register(:create_post, kind: :action, controller: posts_controller)
          expect(registry.clear!).to be(registry)
          expect(registry).to be_empty
        end
      end

      describe "Story 8.3 — mixed controller+standalone collision", :story_8_3 do
        let(:posts_controller_class) do
          Class.new { def self.name = "PostsController" }
        end

        let(:standalone_create_post_module) do
          Module.new do
            extend Ruact::ServerAction

            def self.name
              "CreatePost"
            end
          end
        end

        it "raises Ruact::ConfigurationError when the same Ruby symbol is declared in a controller " \
           "AND in a standalone module — message names BOTH hosts" do
          registry.register(:create_post, kind: :action, controller: posts_controller_class)

          expect do
            registry.register(:create_post, kind: :action, controller: standalone_create_post_module)
          end.to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to include(":create_post")
            expect(error.message).to include("PostsController")
            expect(error.message).to include("CreatePost")
            expect(error.message).to include("declared in BOTH")
          end
        end

        it "raises Ruact::ConfigurationError when the same symbol is declared in standalone " \
           "first, then in a controller (order-independent)" do
          registry.register(:create_post, kind: :action, controller: standalone_create_post_module)

          expect do
            registry.register(:create_post, kind: :action, controller: posts_controller_class)
          end.to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to include("PostsController")
            expect(error.message).to include("CreatePost")
          end
        end

        it "uses kind-neutral 'Each server-function symbol' wording when an action and a query " \
           "collide on the same Ruby symbol across DIFFERENT controllers (Story 9.1 F4 — the " \
           "Registry is shared by both DSLs so the hard-coded `Each ruact_action symbol` was " \
           "wrong)", :aggregate_failures, :story_9_1 do
          query_controller = Class.new { def self.name = "ProductsController" }
          registry.register(:create_post, kind: :action, controller: posts_controller_class)

          register_query = -> { registry.register(:create_post, kind: :query, controller: query_controller) }
          expect(&register_query).to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to start_with("server-function naming collision:")
            expect(error.message).to include(":create_post is declared in BOTH")
            expect(error.message).to include("PostsController")
            expect(error.message).to include("ProductsController")
            # F4: cross-kind collision uses the generic label, not the action-only wording
            expect(error.message).to include("Each server-function symbol must be unique")
            expect(error.message).not_to include("Each `ruact_action` symbol must be unique")
          end
        end

        it "keeps the original 'Each `ruact_action` symbol' wording when BOTH sides are actions " \
           "(Story 9.1 F4 — single-DSL collision retains the precise label)", :aggregate_failures, :story_9_1 do
          other_controller = Class.new { def self.name = "AdminPostsController" }
          registry.register(:create_post, kind: :action, controller: posts_controller_class)

          register_dup = -> { registry.register(:create_post, kind: :action, controller: other_controller) }
          expect(&register_dup).to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to include("Each `ruact_action` symbol must be unique")
          end
        end

        it "uses 'Each `ruact_query` symbol' wording when BOTH sides are queries " \
           "(Story 9.1 F4 — single-DSL collision retains the precise label for queries too)",
           :aggregate_failures, :story_9_1 do
          other_controller = Class.new { def self.name = "AdminProductsController" }
          registry.register(:categories, kind: :query, controller: posts_controller_class)

          register_dup = -> { registry.register(:categories, kind: :query, controller: other_controller) }
          expect(&register_dup).to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to include("Each `ruact_query` symbol must be unique")
          end
        end

        it "describe_controller names a Module host correctly (no inspection fallback) " \
           "when one side of the collision is a Module" do
          registry.register(:create_post, kind: :action, controller: standalone_create_post_module)
          another_module = Module.new do
            extend Ruact::ServerAction

            def self.name
              "AdminCreatePost"
            end
          end

          # Cross-bridge JS-identifier collision: two DIFFERENT Ruby symbols
          # producing the SAME JS identifier — bridges into `js_identifier ==`
          # branch of detect_collision!. The bridge collapses underscores,
          # so `:create_post` and `:create__post` both → "createPost".
          expect do
            registry.register(:create__post, kind: :action, controller: another_module)
          end.to raise_error(Ruact::ConfigurationError) do |error|
            expect(error.message).to include("CreatePost")
            expect(error.message).to include("AdminCreatePost")
            expect(error.message).to include('"createPost"')
          end
        end
      end

      describe "Ruact module-level accessors (Story 8.0a)" do
        it "returns two independent Registry singletons" do
          expect(Ruact.action_registry).to be_a(described_class)
          expect(Ruact.query_registry).to be_a(described_class)
          expect(Ruact.action_registry).not_to equal(Ruact.query_registry)
        end

        it "memoizes the same instance across calls" do
          expect(Ruact.action_registry).to equal(Ruact.action_registry)
          expect(Ruact.query_registry).to equal(Ruact.query_registry)
        end

        it "both registries are empty at boot (Story 8.1 / 9.1 populate them)" do
          expect(Ruact.action_registry).to be_empty
          expect(Ruact.query_registry).to be_empty
        end
      end
    end
  end
end
