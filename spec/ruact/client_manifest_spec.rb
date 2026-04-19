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
  end
end
