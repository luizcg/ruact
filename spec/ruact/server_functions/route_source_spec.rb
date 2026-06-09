# frozen_string_literal: true

require "spec_helper"
require "active_support/all"
require "action_dispatch"
require "ruact/server_functions/route_source"

module Ruact
  module ServerFunctions
    # Story 9.3 — route introspection: Rails.application.routes (filtered to
    # non-GET routes on controllers that include Ruact::Server) → v2 mutation
    # entries with the derivation table locked in the 2026-06-09 ADR addendum.
    RSpec.describe RouteSource, :story_9_3 do
      # Builds an isolated RouteSet so specs never depend on a host app's routes.
      def route_set(&blk)
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw(&blk)
        rs
      end

      # All controllers count as Ruact::Server hosts (isolates the derivation
      # table from constant-resolution); the filter behaviour is tested
      # separately below.
      def collect(routes, overrides: {})
        described_class.collect(
          routes,
          host_predicate: ->(_controller) { true },
          overrides_for: ->(controller) { overrides.fetch(controller, {}) }
        )
      end

      def ids(entries) = entries.map { |e| e["js_identifier"] }

      describe "derivation table (AC3)" do
        it "names the RESTful collection create as singular verb+resource" do
          rs = route_set { resources :posts, only: %i[create] }
          entry = collect(rs).fetch(0)
          expect(entry["js_identifier"]).to eq("createPost")
          expect(entry["http_method"]).to eq("POST")
          expect(entry["path"]).to eq("/posts")
          expect(entry["segments"]).to eq([])
          expect(entry["kind"]).to eq("action")
        end

        it "names update (member) singular and prefers PATCH over the PUT alias" do
          rs = route_set { resources :posts, only: %i[update] }
          entries = collect(rs)
          expect(entries.size).to eq(1) # PATCH + PUT collapse to one entry
          entry = entries.fetch(0)
          expect(entry["js_identifier"]).to eq("updatePost")
          expect(entry["http_method"]).to eq("PATCH")
          expect(entry["path"]).to eq("/posts/:id")
          expect(entry["segments"]).to eq(["id"])
        end

        it "names destroy (member) singular" do
          rs = route_set { resources :posts, only: %i[destroy] }
          entry = collect(rs).fetch(0)
          expect(entry["js_identifier"]).to eq("destroyPost")
          expect(entry["http_method"]).to eq("DELETE")
          expect(entry["path"]).to eq("/posts/:id")
        end

        it "skips the GET RESTful actions (index/show/new/edit)" do
          rs = route_set { resources :posts }
          expect(ids(collect(rs))).to match_array(%w[createPost updatePost destroyPost])
        end

        it "names a custom member route singular (verb-action + singular resource)" do
          rs = route_set do
            resources :posts do
              member { post :publish }
            end
          end
          entry = collect(rs).find { |e| e["js_identifier"] == "publishPost" }
          expect(entry).not_to be_nil
          expect(entry["http_method"]).to eq("POST")
          expect(entry["path"]).to eq("/posts/:id/publish")
          expect(entry["segments"]).to eq(["id"])
        end

        it "names a custom collection route plural" do
          rs = route_set do
            resources :posts do
              collection { post :publish_all }
            end
          end
          entry = collect(rs).find { |e| e["js_identifier"] == "publishAllPosts" }
          expect(entry).not_to be_nil
          expect(entry["path"]).to eq("/posts/publish_all")
          expect(entry["segments"]).to eq([])
        end

        it "names singular-resource create/destroy singular" do
          rs = route_set { resource :session, only: %i[create destroy] }
          expect(ids(collect(rs))).to match_array(%w[createSession destroySession])
        end

        it "prefixes namespaced controllers (verb + Namespace + Resource)" do
          rs = route_set { namespace(:admin) { resources :posts, only: %i[create update] } }
          expect(ids(collect(rs))).to match_array(%w[createAdminPost updateAdminPost])
        end

        it "deep-prefixes multi-level namespaces" do
          rs = route_set do
            namespace(:admin) { namespace(:reports) { resources :posts, only: %i[create] } }
          end
          expect(ids(collect(rs))).to eq(%w[createAdminReportsPost])
        end

        it "sorts entries by js_identifier for deterministic output" do
          rs = route_set { resources :posts }
          expect(ids(collect(rs))).to eq(%w[createPost destroyPost updatePost])
        end

        it "classifies a custom-param member route (param: :slug) as member → singular" do
          rs = route_set do
            resources :posts, param: :slug do
              member { post :publish }
            end
          end
          entry = collect(rs).find { |e| e["action"] == "publish" }
          expect(entry["js_identifier"]).to eq("publishPost")
          expect(entry["segments"]).to eq(["slug"])
        end

        it "classifies a nested collection route (only parent :id present) as collection → plural" do
          rs = route_set do
            resources :posts, only: [] do
              resources :comments, only: [] do
                collection { post :flag_all }
              end
            end
          end
          entry = collect(rs).find { |e| e["action"] == "flag_all" }
          expect(entry["js_identifier"]).to eq("flagAllComments")
        end
      end

      describe "rename override (AC4 input)" do
        it "uses the per-controller override identifier when present" do
          rs = route_set do
            resources :posts do
              collection { post :publish_all }
            end
          end
          entries = collect(rs, overrides: { "posts" => { "publish_all" => "publishEverything" } })
          expect(ids(entries)).to include("publishEverything")
          expect(ids(entries)).not_to include("publishAllPosts")
        end
      end

      describe "collision detection (AC4)" do
        it "fails loudly naming BOTH origins when two routes map to the same identifier" do
          rs = route_set do
            resources :posts, only: %i[create]
            resources :comments, only: %i[create]
          end
          # Force a collision: comments#create is renamed onto posts#create's name.
          overrides = { "comments" => { "create" => "createPost" } }
          expect do
            collect(rs, overrides: overrides)
          end.to raise_error(Ruact::ConfigurationError, /naming collision/) { |err|
            expect(err.message).to include("posts#create")
            expect(err.message).to include("comments#create")
            expect(err.message).to include("createPost")
          }
        end

        it "boot succeeds once the colliding route is renamed to a free identifier (full cycle)" do
          rs = route_set do
            resources :posts, only: %i[create]
            resources :comments, only: %i[create]
          end
          overrides = { "comments" => { "create" => "createComment" } }
          ids_out = ids(collect(rs, overrides: overrides))
          expect(ids_out).to eq(%w[createComment createPost])
        end
      end

      describe "host filter (Ruact::Server only)" do
        it "skips routes whose controller is not a Ruact::Server host" do
          rs = route_set do
            resources :posts, only: %i[create]
            resources :widgets, only: %i[create]
          end
          entries = described_class.collect(
            rs,
            host_predicate: ->(controller) { controller == "posts" },
            overrides_for: ->(_c) { {} }
          )
          expect(ids(entries)).to eq(%w[createPost])
        end

        it "skips GET/HEAD routes even on a host controller" do
          rs = route_set { get "/posts/search", to: "posts#search" }
          expect(collect(rs)).to be_empty
        end
      end
    end
  end
end
