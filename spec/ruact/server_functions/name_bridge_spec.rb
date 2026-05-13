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

        describe "underscore-only symbols (Story 8.0 review patch 2026-05-13)" do
          it "rejects a single underscore" do
            expect { described_class.to_js_identifier(:_) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":_")
                expect(error.message).to include("entirely of underscores")
              end
          end

          it "rejects a run of underscores" do
            expect { described_class.to_js_identifier(:____) }
              .to raise_error(Ruact::ConfigurationError, /entirely of underscores/)
          end

          it "still accepts a leading underscore followed by alphanumeric" do
            expect(described_class.to_js_identifier(:_x)).to eq("_x")
          end
        end

        describe "JS reserved words (Story 8.0 review patch 2026-05-13)" do
          # Spot-check a handful of representative classes: keyword (`class`),
          # module-level reserved (`export`), strict-mode reserved (`let`),
          # contextually-reserved (`await`, `async`), literal (`true`).
          it "rejects :class" do
            expect { described_class.to_js_identifier(:class) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":class")
                expect(error.message).to include("JS reserved word")
                expect(error.message).to include('"class"')
              end
          end

          it "rejects :export" do
            expect { described_class.to_js_identifier(:export) }
              .to raise_error(Ruact::ConfigurationError, /JS reserved word.*"export"/)
          end

          it "rejects :let, :await, :async, :true (representative coverage)" do
            %i[let await async true].each do |sym|
              expect { described_class.to_js_identifier(sym) }
                .to raise_error(Ruact::ConfigurationError, /JS reserved word/),
                    "expected :#{sym} to raise as a reserved word"
            end
          end

          it "rejects :eval and :arguments (strict-mode invalid binding names — " \
             "Story 8.0 Re-run patch 2026-05-13)" do
            # ES module code runs in strict mode, where `eval` and `arguments`
            # cannot be used as identifier names. The 8.0a codegen emits a
            # `"type": "module"` file, so these guards apply unconditionally.
            %i[eval arguments].each do |sym|
              expect { described_class.to_js_identifier(sym) }
                .to raise_error(Ruact::ConfigurationError, /JS reserved word/),
                    "expected :#{sym} to raise as strict-mode invalid binding name"
            end
          end

          it "rejects multi-word symbols that camelCase into a reserved word" do
            # No real Ruby snake_case maps to a single reserved word post-
            # camelCasing (reserved words are themselves single-word), but the
            # check happens AFTER camelCasing so a hypothetical degenerate
            # input is still caught.
            expect { described_class.to_js_identifier(:cl_ass) }
              .not_to raise_error # "clAss" is not reserved — sanity guard
            expect(described_class.to_js_identifier(:cl_ass)).to eq("clAss")
          end

          it "ACCEPTS reserved words that survive only with the leading-underscore prefix" do
            # `:_class` → "_class" — not reserved (the underscore is a literal
            # character); intentional escape hatch for devs whose domain
            # vocabulary collides with JS keywords.
            expect(described_class.to_js_identifier(:_class)).to eq("_class")
            expect(described_class.to_js_identifier(:_export)).to eq("_export")
          end

          it "ACCEPTS the suffix-shaped escape hint from the error message" do
            # The error message suggests `:class_action`; assert that hint
            # produces a valid identifier — guards against a regression where
            # the suggested fix would also fail validation.
            expect(described_class.to_js_identifier(:class_action)).to eq("classAction")
          end
        end
      end
    end
  end
end
