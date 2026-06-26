# frozen_string_literal: true

require "spec_helper"
require "tempfile"

module Ruact
  RSpec.describe ClientManifest do
    let(:manifest_data) do
      {
        "LikeButton" => {
          "id" => "/LikeButton.jsx",
          "name" => "LikeButton",
          "chunks" => ["/LikeButton.jsx"]
        }
      }
    end

    let(:dual_manifest_data) do
      {
        "LikeButton" => {
          "id" => "/LikeButton.jsx",
          "name" => "LikeButton",
          "chunks" => ["/LikeButton.jsx"]
        },
        "posts/_like_button" => {
          "id" => "/posts/_like_button.jsx",
          "name" => "default",
          "chunks" => ["/posts/_like_button.jsx"]
        }
      }
    end

    describe "#include?" do
      let(:manifest) { described_class.from_hash(manifest_data) }

      it "returns true for a key present in the manifest" do
        expect(manifest.include?("LikeButton")).to be true
      end

      it "returns false for a key absent from the manifest" do
        expect(manifest.include?("posts/_like_button")).to be false
      end
    end

    describe "#reference_for with controller_path:" do
      let(:shared_only_manifest) { described_class.from_hash(manifest_data) }
      let(:dual_manifest)        { described_class.from_hash(dual_manifest_data) }

      it "uses shared key when no controller_path given (AC#1)" do
        ref = shared_only_manifest.reference_for("LikeButton")
        expect(ref.module_id).to eq("/LikeButton.jsx")
      end

      it "uses co-located key when it exists in the manifest (AC#2)" do
        ref = dual_manifest.reference_for("LikeButton", controller_path: "posts")
        expect(ref.module_id).to eq("/posts/_like_button.jsx")
      end

      it "co-located takes precedence over shared when both exist (AC#3)" do
        ref = dual_manifest.reference_for("LikeButton", controller_path: "posts")
        expect(ref.module_id).to eq("/posts/_like_button.jsx")
        expect(ref.module_id).not_to eq("/LikeButton.jsx")
      end

      it "falls back to shared when co-located key absent (AC#4)" do
        ref = dual_manifest.reference_for("LikeButton", controller_path: "articles")
        expect(ref.module_id).to eq("/LikeButton.jsx")
      end

      it "looks in comments/ first, finds none, uses shared (AC#5)" do
        ref = dual_manifest.reference_for("LikeButton", controller_path: "comments")
        expect(ref.module_id).to eq("/LikeButton.jsx")
      end

      it "returns the same object for repeated calls (dedup by object_id)" do
        ref1 = dual_manifest.reference_for("LikeButton", controller_path: "posts")
        ref2 = dual_manifest.reference_for("LikeButton", controller_path: "posts")
        expect(ref1).to equal(ref2)
      end

      it "shared and co-located references are different objects" do
        shared = dual_manifest.reference_for("LikeButton")
        co_loc = dual_manifest.reference_for("LikeButton", controller_path: "posts")
        expect(shared).not_to equal(co_loc)
      end
    end

    describe ".load" do
      let(:loaded_manifest) do
        Tempfile.create(["manifest", ".json"]) do |f|
          f.write(manifest_data.to_json)
          f.flush
          described_class.load(f.path)
        end
      end

      it "returns a frozen manifest (AC#5)" do
        expect(loaded_manifest).to be_frozen
      end

      it "allows reference_for on a frozen manifest without raising (AC#5)" do
        expect { loaded_manifest.reference_for("LikeButton") }.not_to raise_error
      end

      it "resolves the correct ClientReference from a frozen manifest (AC#5)" do
        ref = loaded_manifest.reference_for("LikeButton")
        expect(ref).to be_a(Flight::ClientReference)
        expect(ref.module_id).to eq("/LikeButton.jsx")
      end

      it "raises ManifestError for unknown component with actionable message (AC#1)" do
        expect { loaded_manifest.reference_for("Unknown") }
          .to raise_error(Ruact::ManifestError, /Unknown/)
        expect { loaded_manifest.reference_for("Unknown") }
          .to raise_error(Ruact::ManifestError, /Did you run the Vite build\?/)
      end
    end

    describe ".from_hash" do
      it "returns a mutable manifest (not frozen)" do
        manifest = described_class.from_hash(manifest_data)
        expect(manifest).not_to be_frozen
      end
    end

    describe "#contract_for (Story 13.5)", :story_13_5 do
      let(:contract) { { "props" => { "postId" => "required" } } }

      it "returns the optional contract Hash when present" do
        manifest = described_class.from_hash(
          "LikeButton" => manifest_data["LikeButton"].merge("contract" => contract)
        )
        expect(manifest.contract_for("LikeButton")).to eq(contract)
      end

      it "returns nil when the component declares no contract (back-compat)" do
        manifest = described_class.from_hash(manifest_data)
        expect(manifest.contract_for("LikeButton")).to be_nil
      end

      it "returns nil for an unknown component (never raises — fail open)" do
        manifest = described_class.from_hash(manifest_data)
        expect(manifest.contract_for("Nope")).to be_nil
      end

      it "honors the co-located/shared resolve_key precedence" do
        data = dual_manifest_data.dup
        data["posts/_like_button"] = data["posts/_like_button"].merge("contract" => contract)
        manifest = described_class.from_hash(data)
        expect(manifest.contract_for("LikeButton", controller_path: "posts")).to eq(contract)
        expect(manifest.contract_for("LikeButton")).to be_nil
      end

      it "reads cleanly from a frozen manifest" do
        manifest = described_class.from_hash(
          "LikeButton" => manifest_data["LikeButton"].merge("contract" => contract)
        ).freeze
        expect(manifest.contract_for("LikeButton")).to eq(contract)
      end
    end

    describe "#reference_for closest-match suggestion (Story 7.4)" do
      let(:shared_only_manifest) { described_class.from_hash(manifest_data) }
      let(:dual_manifest)        { described_class.from_hash(dual_manifest_data) }

      it "suggests the shared key for a one-character typo" do
        expect { shared_only_manifest.reference_for("LikeButtonn") }
          .to raise_error(Ruact::ManifestError, /Did you mean "LikeButton"\?/)
      end

      it "suggests the shared key for a two-character typo (boundary)" do
        # "LiekButtoon" is the AC7 spec 13 boundary case (transposition + one
        # insertion); under Damerau-Levenshtein its distance from "LikeButton"
        # is 2, so the suggestion fires.
        expect { shared_only_manifest.reference_for("LiekButtoon") }
          .to raise_error(Ruact::ManifestError, /Did you mean "LikeButton"\?/)
      end

      it "falls back to the file-path hint when the typo is over distance 2" do
        expect { shared_only_manifest.reference_for("LkkButttn") }
          .to raise_error(Ruact::ManifestError) do |error|
            expect(error.message)
              .to match(%r{Did you mean to add app/javascript/components/LkkButttn\.jsx and rebuild Vite\?})
            expect(error.message).not_to match(/Did you mean "LikeButton"\?/)
          end
      end

      it "falls back to the file-path hint for a totally unrelated name" do
        expect { shared_only_manifest.reference_for("Whatever") }
          .to raise_error(Ruact::ManifestError,
                          %r{Did you mean to add app/javascript/components/Whatever\.jsx and rebuild Vite\?})
      end

      it "suggests a co-located key (with original key shown) when it is the closest match" do
        co_located_only = described_class.from_hash(
          "posts/_like_button" => {
            "id" => "/posts/_like_button.jsx",
            "name" => "default",
            "chunks" => ["/posts/_like_button.jsx"]
          }
        )
        expect { co_located_only.reference_for("LikeButtoon") }
          .to raise_error(Ruact::ManifestError, %r{Did you mean "posts/_like_button"\?})
      end

      it "biases the suggestion toward co-located keys when controller_path is given" do
        # Both "LikeButton" (shared) and "posts/_like_button" (co-located) tie
        # at distance 1 from "LikeButtoon". Without controller_path the first
        # one encountered wins (hash-iteration order); with controller_path:"posts"
        # the co-located key is preferred so the suggestion is contextual.
        expect { dual_manifest.reference_for("LikeButtoon", controller_path: "posts") }
          .to raise_error(Ruact::ManifestError, %r{Did you mean "posts/_like_button"\?})
      end

      it "preserves the existing 'Did you run the Vite build?' hint in every variant" do
        vite_hint = /Did you run the Vite build\? Run 'npm run build' or start the Vite dev server\./
        expect { shared_only_manifest.reference_for("LikeButtonn") }
          .to raise_error(Ruact::ManifestError, vite_hint)
        expect { shared_only_manifest.reference_for("Whatever") }
          .to raise_error(Ruact::ManifestError, vite_hint)
      end

      it "uses the AC3 verbatim multi-line 'ruact:' message shape" do
        expect { shared_only_manifest.reference_for("LikeButtonn") }
          .to raise_error(Ruact::ManifestError) do |error|
            expect(error.message).to eq(<<~MSG.strip)
              ruact: Component "LikeButtonn" not found in manifest.
                Did you mean "LikeButton"?
                Did you run the Vite build? Run 'npm run build' or start the Vite dev server.
            MSG
          end
      end
    end

    describe "edge cases (Story 7.4)" do
      it "does not raise FrozenError when an empty loaded manifest looks up an unknown component" do
        empty_manifest = Tempfile.create(["empty_manifest", ".json"]) do |f|
          f.write("{}")
          f.flush
          described_class.load(f.path)
        end

        expect(empty_manifest).to be_frozen
        expect { empty_manifest.reference_for("LikeButton") }
          .to raise_error(Ruact::ManifestError, /not found in manifest/)
      end

      it "uses entry['name'] (not the lookup key) for ClientReference#export_name" do
        manifest = described_class.from_hash(
          "LikeButton" => {
            "id" => "/LikeButton.jsx",
            "name" => "LikeButton",
            "chunks" => ["/LikeButton.jsx"]
          },
          "posts/_like_button" => {
            "id" => "/posts/_like_button.jsx",
            "name" => "default",
            "chunks" => ["/posts/_like_button.jsx"]
          }
        )

        shared_ref     = manifest.reference_for("LikeButton")
        co_located_ref = manifest.reference_for("LikeButton", controller_path: "posts")

        expect(shared_ref.export_name).to eq("LikeButton")
        expect(co_located_ref.export_name).to eq("default")
      end
    end
  end
end
