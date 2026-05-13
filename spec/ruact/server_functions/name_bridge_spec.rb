# frozen_string_literal: true

require "spec_helper"

module Ruact
  module ServerFunctions
    RSpec.describe NameBridge, :story_8_0a do
      describe ".to_js_identifier (Story 8.0a — Ruby symbol → JS identifier)" do
        # Six canonical edge cases locked by the Story 8.0 ADR.

        it "translates standard snake_case to camelCase" do
          expect(described_class.to_js_identifier(:create_post)).to eq("createPost")
        end

        it "passes a single word through unchanged" do
          expect(described_class.to_js_identifier(:categories)).to eq("categories")
        end

        it "preserves a single leading underscore" do
          expect(described_class.to_js_identifier(:_internal_dump)).to eq("_internalDump")
        end

        it "collapses consecutive underscores" do
          expect(described_class.to_js_identifier(:foo__bar)).to eq("fooBar")
        end

        it "raises ConfigurationError for SCREAMING_SNAKE" do
          expect { described_class.to_js_identifier(:RECALCULATE) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to include(":RECALCULATE")
              expect(error.message).to include("/^[a-z_][a-z0-9_]*$/")
            end
        end

        it "raises ConfigurationError for PascalCase" do
          expect { described_class.to_js_identifier(:CreatePost) }
            .to raise_error(Ruact::ConfigurationError) do |error|
              expect(error.message).to include(":CreatePost")
              expect(error.message).to include("ruact_action / ruact_query")
            end
        end

        describe "additional shape guards" do
          it "rejects symbols starting with a digit" do
            expect { described_class.to_js_identifier(:"1foo") }
              .to raise_error(Ruact::ConfigurationError, /must match/)
          end

          it "rejects symbols containing a dash" do
            expect { described_class.to_js_identifier(:"foo-bar") }
              .to raise_error(Ruact::ConfigurationError, /must match/)
          end

          it "rejects empty string" do
            expect { described_class.to_js_identifier(:"") }
              .to raise_error(Ruact::ConfigurationError, /must match/)
          end

          it "accepts a string argument identical to its symbol form" do
            expect(described_class.to_js_identifier("create_post")).to eq("createPost")
          end

          it "preserves a leading underscore followed by digits" do
            expect(described_class.to_js_identifier(:_2fa_check)).to eq("_2faCheck")
          end
        end
      end
    end
  end
end
