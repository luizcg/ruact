# frozen_string_literal: true

# Story 13.3 (FR98) — unit specs for the pure validation-error normalizer
# Ruact::ServerFunctions::ValidationErrors.normalize. The normalizer turns an
# ActiveModel-ish record, a raw ActiveModel::Errors, or a pre-shaped Hash into
# the canonical wire shape `{ [attribute: String] => Array<String> }` (full
# messages, `base` key, `{}` on a valid/empty/nil source, idempotent on
# already-canonical input). Pure — no Rails/request/Ruact.config reads.

require "spec_helper"
require "active_model"

require "ruact/server_functions/validation_errors"

module Ruact
  module ServerFunctions
    RSpec.describe ValidationErrors, :story_13_3 do
      # A minimal ActiveModel record so the normalizer can exercise the real
      # `errors.group_by_attribute` / `ActiveModel::Error#full_message` API
      # (present since Rails 6.1; gem pins `rails ~> 8.0`).
      let(:record_class) do
        Class.new do
          include ActiveModel::Model
          include ActiveModel::Attributes

          attribute :title, :string
          attribute :body, :string

          def self.name = "ValidationErrorsSpecPost"
        end
      end

      describe ".normalize" do
        context "with a record responding to #errors" do
          it "returns the canonical { attr => [full_message] } shape" do
            record = record_class.new
            record.errors.add(:title, :blank) # "Title can't be blank"

            expect(described_class.normalize(record)).to eq("title" => ["Title can't be blank"])
          end

          it "keys base-level errors under the string 'base' with the bare message" do
            record = record_class.new
            record.errors.add(:base, "is invalid overall")

            expect(described_class.normalize(record)).to eq("base" => ["is invalid overall"])
          end

          it "groups multiple attributes and multiple messages per attribute" do
            record = record_class.new
            record.errors.add(:title, :blank)              # "Title can't be blank"
            record.errors.add(:title, "is too short")      # "Title is too short"
            record.errors.add(:body, "is invalid")         # "Body is invalid"

            expect(described_class.normalize(record)).to eq(
              "title" => ["Title can't be blank", "Title is too short"],
              "body" => ["Body is invalid"]
            )
          end

          it "returns {} for a record with no errors (success symmetry)" do
            expect(described_class.normalize(record_class.new)).to eq({})
          end
        end

        context "with a raw ActiveModel::Errors" do
          it "normalizes the Errors object directly" do
            record = record_class.new
            record.errors.add(:title, :blank)

            expect(described_class.normalize(record.errors)).to eq("title" => ["Title can't be blank"])
          end
        end

        context "with a pre-shaped Hash" do
          it "stringifies keys and leaves canonical array values untouched (idempotent)" do
            canonical = { "title" => ["Title can't be blank"] }

            expect(described_class.normalize(canonical)).to eq(canonical)
          end

          it "stringifies symbol keys" do
            expect(described_class.normalize(title: ["x"])).to eq("title" => ["x"])
          end

          it "coerces a scalar value into a one-element array" do
            expect(described_class.normalize("title" => "can't be blank")).to eq("title" => ["can't be blank"])
          end

          it "coerces non-string message values to strings" do
            expect(described_class.normalize("count" => [1, 2])).to eq("count" => %w[1 2])
          end

          it "returns {} for an empty Hash" do
            expect(described_class.normalize({})).to eq({})
          end
        end

        context "with nil / empty sources" do
          it "returns {} for nil" do
            expect(described_class.normalize(nil)).to eq({})
          end
        end

        it "is idempotent — normalizing its own output yields the same Hash" do
          record = record_class.new
          record.errors.add(:title, :blank)
          record.errors.add(:base, "is invalid overall")

          once = described_class.normalize(record)
          expect(described_class.normalize(once)).to eq(once)
        end
      end
    end
  end
end
