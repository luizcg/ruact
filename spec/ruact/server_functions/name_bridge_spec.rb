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
              expect(error.message).to include("ruact server-function name")
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

          it "accepts multi-word symbols whose camelCased output is not reserved" do
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

        describe "Ruact-reserved names (Story 8.2 review patch R2 — 2026-05-17)", :story_8_2 do
          # The codegen unconditionally re-exports certain runtime helpers
          # from `@/.ruact/server-functions` (e.g. `revalidate`). A server
          # function named `revalidate` would emit `export const revalidate`
          # next to the helper re-export and crash at module load with a
          # duplicate-export error. Reject at route-draw instead.
          it "rejects :revalidate because it collides with the unconditional helper re-export" do
            expect { described_class.to_js_identifier(:revalidate) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":revalidate")
                expect(error.message).to include("duplicate export")
              end
          end

          it "accepts :revalidate_post (suffix escape hatch — same convention as JS reserved-word path)" do
            expect(described_class.to_js_identifier(:revalidate_post)).to eq("revalidatePost")
          end

          it "accepts :_revalidate (leading-underscore escape hatch)" do
            expect(described_class.to_js_identifier(:_revalidate)).to eq("_revalidate")
          end

          it "rejects :_make_server_function because it collides with the codegen's runtime import" do
            expect { described_class.to_js_identifier(:_make_server_function) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":_make_server_function")
                expect(error.message).to include("duplicate export")
              end
          end

          it "accepts :_make_ref now that the demolished v1 runtime export is no longer reserved (Story 9.9)" do
            expect(described_class.to_js_identifier(:_make_ref)).to eq("_makeRef")
          end

          # Story 9.5 — `_makeQuery` (the v2 query import) and `useQuery` (the
          # query hook re-export) are new top-level bindings in the generated
          # module; a query/action method mapping to either would redeclare the
          # import / duplicate the export and crash at module load.
          it "Story 9.5 — rejects :use_query because it collides with the useQuery re-export" do
            expect { described_class.to_js_identifier(:use_query) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":use_query")
                expect(error.message).to include("duplicate export")
              end
          end

          it "Story 9.5 — rejects :_make_query because it collides with the codegen's runtime import" do
            expect { described_class.to_js_identifier(:_make_query) }
              .to raise_error(Ruact::ConfigurationError) do |error|
                expect(error.message).to include(":_make_query")
                expect(error.message).to include("duplicate export")
              end
          end

          it "Story 9.5 — accepts :use_query_results (suffix escape hatch keeps working)" do
            expect(described_class.to_js_identifier(:use_query_results)).to eq("useQueryResults")
          end
        end
      end
    end
  end
end
