# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ComponentContract, :story_13_5 do
    def validate(prop_names, contract)
      described_class.validate(
        component_name: "LikeButton", prop_names: prop_names, contract: contract,
        at: { file: "app/views/posts/show.html.erb", line: 7, snippet: "<LikeButton ... />" }
      )
    end

    describe "fail open" do
      it "is a no-op when the contract is nil (opt-in)" do
        expect { validate(%w[anything goes], nil) }.not_to raise_error
      end
    end

    describe "missing required prop (AC#1, AC#3)" do
      let(:contract) { { "props" => { "postId" => "required", "size" => "optional" } } }

      it "raises ComponentContractError naming the component, file:line, prop, and a fix" do
        expect { validate(["size"], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("LikeButton")
          expect(e.message).to include("app/views/posts/show.html.erb:7")
          expect(e.message).to include("postId")
          expect(e.message).to include("add the required prop")
        end
      end

      it "is a PreprocessorError (NFR30 overlay lineage)" do
        expect { validate([], contract) }.to raise_error(PreprocessorError)
      end

      it "passes when the required prop is present" do
        expect { validate(%w[postId size], contract) }.not_to raise_error
      end
    end

    describe "unknown prop with did-you-mean (AC#1, AC#3)" do
      let(:contract) { { "props" => { "postId" => "required", "initialCount" => "optional" } } }

      it "raises with a Damerau-Levenshtein closest-match suggestion for a near typo" do
        expect { validate(%w[postId postID], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("unknown prop")
          expect(e.message).to include("postID")
          expect(e.message).to include('did you mean "postId"?')
        end
      end

      it "raises without a suggestion when nothing is close" do
        expect { validate(%w[postId zzzzzzzz], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("zzzzzzzz")
          expect(e.message).not_to include("did you mean")
        end
      end

      it "allows undeclared props when passthrough is true" do
        open = contract.merge("passthrough" => true)
        expect { validate(%w[postId whatever], open) }.not_to raise_error
      end

      # Codex review (Patch 1) — a typo OF a required prop (the required name is
      # therefore "missing") must surface the did-you-mean, not the less-helpful
      # "missing required" message. FR100's canonical postID/postId case.
      it "prefers the did-you-mean when the only prop is a typo of a missing required prop" do
        expect { validate(%w[postID], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("unknown prop")
          expect(e.message).to include('did you mean "postId"?')
          expect(e.message).not_to include("missing required")
        end
      end

      it "still reports the missing required prop when the unknown prop is NOT a near typo" do
        expect { validate(%w[zzzzzzzz], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("missing required prop")
          expect(e.message).to include("postId")
        end
      end
    end

    describe "slots (AC#5)" do
      let(:contract) do
        { "props" => { "title" => "required" }, "slots" => { "header" => "required", "footer" => "optional" } }
      end

      it "raises when a required slot is omitted" do
        expect { validate(%w[title], contract) }.to raise_error(ComponentContractError) do |e|
          expect(e.message).to include("missing required slot")
          expect(e.message).to include("header")
        end
      end

      it "treats a declared slot name as a valid attribute (not unknown)" do
        expect { validate(%w[title header], contract) }.not_to raise_error
      end

      it "accepts the array form (all optional) and is a no-op when slots are absent" do
        arr = { "props" => { "title" => "required" }, "slots" => %w[header footer] }
        expect { validate(%w[title], arr) }.not_to raise_error
      end

      it "does nothing when the contract declares no slots" do
        expect { validate(%w[title], { "props" => { "title" => "required" } }) }.not_to raise_error
      end
    end

    describe "location formatting" do
      it "degrades gracefully when file/line are absent" do
        expect do
          described_class.validate(
            component_name: "X", prop_names: [], contract: { "props" => { "a" => "required" } }
          )
        end.to raise_error(ComponentContractError, /unknown location/)
      end
    end
  end
end
