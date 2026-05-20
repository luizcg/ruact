# frozen_string_literal: true

require "spec_helper"
require "ruact/server_functions/error_suggestion"

module Ruact
  module ServerFunctions
    RSpec.describe ErrorSuggestion, :story_8_4 do
      # Test fixtures using class-name spoofing so the module can be exercised
      # without requiring ActiveRecord or ActionController to be loaded
      # (Pitfall #4).
      def error_with_class_name(name)
        klass = Class.new(StandardError) do
          define_singleton_method(:name) { name }
        end
        klass.new("fixture")
      end

      describe "Story 8.4 — .for returns the NFR30-mandated suggestion" do
        it "returns the RecordInvalid suggestion for ActiveRecord::RecordInvalid" do
          err = error_with_class_name("ActiveRecord::RecordInvalid")
          expect(described_class.for(err))
            .to eq("Validation failed — check the model's `validates` rules")
        end

        it "returns the CSRF suggestion for ActionController::InvalidAuthenticityToken" do
          err = error_with_class_name("ActionController::InvalidAuthenticityToken")
          expect(described_class.for(err))
            .to eq(
              "CSRF token mismatch — ensure the page was rendered after the most recent server restart and the session cookie is intact"
            )
        end

        it "returns nil for StandardError" do
          expect(described_class.for(StandardError.new("boom"))).to be_nil
        end

        it "returns nil for RuntimeError" do
          expect(described_class.for(RuntimeError.new("boom"))).to be_nil
        end

        it "returns nil for ArgumentError" do
          expect(described_class.for(ArgumentError.new("boom"))).to be_nil
        end

        it "returns nil for a custom user exception class" do
          custom_class = Class.new(StandardError) { define_singleton_method(:name) { "MyApp::PaymentDeclined" } }
          expect(described_class.for(custom_class.new("declined"))).to be_nil
        end
      end

      describe "Story 8.4 — SUGGESTIONS constant" do
        it "is frozen so runtime mutation cannot extend the table" do
          expect(described_class::SUGGESTIONS).to be_frozen
        end

        it "uses class-name strings as keys (not constants)" do
          expect(described_class::SUGGESTIONS.keys).to all(be_a(String))
        end
      end
    end
  end
end
