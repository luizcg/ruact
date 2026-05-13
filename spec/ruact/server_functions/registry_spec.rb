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
