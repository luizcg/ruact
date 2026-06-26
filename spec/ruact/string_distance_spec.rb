# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe StringDistance, :story_13_5 do
    describe ".damerau_levenshtein" do
      it "returns 0 for identical strings" do
        expect(described_class.damerau_levenshtein("postId", "postId")).to eq(0)
      end

      it "counts an adjacent transposition as a single edit" do
        expect(described_class.damerau_levenshtein("postId", "postdI")).to eq(1)
      end

      it "handles empty strings" do
        expect(described_class.damerau_levenshtein("", "abc")).to eq(3)
        expect(described_class.damerau_levenshtein("abc", "")).to eq(3)
      end
    end

    describe ".closest_match" do
      let(:pool) { %w[postId initialCount title] }

      it "finds the nearest candidate within the threshold (case-insensitive)" do
        expect(described_class.closest_match("postID", pool)).to eq("postId")
      end

      it "returns nil when nothing is within distance" do
        expect(described_class.closest_match("zzzzzzzz", pool)).to be_nil
      end

      it "prefers the smallest distance" do
        expect(described_class.closest_match("titel", pool)).to eq("title")
      end
    end
  end
end
