# frozen_string_literal: true

require "spec_helper"

module Ruact
  module Flight
    # Stub bundler config — resolves any module_id/export_name to a simple metadata hash
    class StubBundlerConfig
      def resolve(module_id, export_name)
        [module_id, export_name]
      end
    end

    RSpec.describe "Renderer (serializer integration)" do
      subject(:render) { ->(model) { Renderer.render(model, bundler) } }

      let(:bundler) { StubBundlerConfig.new }

      # --- React Element (DOM) ---
      #
      # Primitive scalar/collection inputs (nil, booleans, integer, float, string,
      # `$`-escaped string, hash, array) are guarded by the fixture-mode block at
      # the bottom of this file. The cases below assert on the *parsed shape* of
      # ReactElement payloads — fixture mode is overkill for them since the
      # invariant under test is "the parsed tuple is `["$", <type>, <key>, <props>]`",
      # not the literal byte sequence.

      describe "ReactElement" do
        it "serializes a DOM element" do
          el = ReactElement.new(type: "div", props: { className: "box", children: "hi" })
          expected = [
            { id: 0, class: :model,
              payload: ["$", "div", nil, { "className" => "box", "children" => "hi" }] }
          ]
          expect(render.call(el)).to match_flight_structure(expected)
        end

        it "serializes a DOM element with a key" do
          el = ReactElement.new(type: "li", key: "item-1", props: { children: "one" })
          expected = [
            { id: 0, class: :model,
              payload: ["$", "li", "item-1", { "children" => "one" }] }
          ]
          expect(render.call(el)).to match_flight_structure(expected)
        end
      end

      # --- Client Reference ---

      describe "ClientReference" do
        it "emits an I row for the import and references $L1 in root" do
          ref = ClientReference.new(module_id: "./LikeButton", export_name: "LikeButton")
          el  = ReactElement.new(type: ref, props: { postId: 1, initialCount: 5 })

          # Story 7.6 Decision B: collapse the original sibling regex pair plus
          # the `out.index("1:I") < out.index("0:[")` ordering check into a
          # single structural assertion. Non-import rows compare positionally,
          # so the import row in expected position 0 + the model row in
          # expected position 1 encode the ordering invariant.
          expected = [
            { id: 1, class: :import, payload: ["./LikeButton", "LikeButton"] },
            { id: 0, class: :model,
              payload: ["$", "$L1", nil, { "postId" => 1, "initialCount" => 5 }] }
          ]
          expect(render.call(el)).to match_flight_structure(expected)
        end

        it "deduplicates: same ClientReference object emits only one I row" do
          ref = ClientReference.new(module_id: "./Button", export_name: "Button")
          el1 = ReactElement.new(type: ref, props: { label: "Save" })
          el2 = ReactElement.new(type: ref, props: { label: "Cancel" })
          out = render.call([el1, el2])

          i_rows = out.scan(/\d+:I/).length
          expect(i_rows).to eq(1), "same ClientReference object should emit only one I row"
        end
      end

      # --- Error handling ---

      describe "unsupported type (AC#2)" do
        it "raises SerializationError with class name and Serializable hint" do
          expect { render.call(Object.new) }
            .to raise_error(Ruact::SerializationError, /Object/)
          expect { render.call(Object.new) }
            .to raise_error(Ruact::SerializationError, /include Ruact::Serializable/)
        end
      end

      # --- Story 2.2: as_json serialization ---

      describe "as_json serialization (Story 2.2)" do
        let(:model_with_as_json) do
          Class.new do
            def as_json
              { "id" => 1, "name" => "Alice" }
            end

            def self.name
              "FakeModel"
            end
          end.new
        end

        let(:model_without_as_json) { Object.new }

        context "with strict_serialization: false (default)" do
          let(:render_loose) do
            b = StubBundlerConfig.new
            ->(model) { Renderer.render(model, b, strict_serialization: false) }
          end

          it "serializes via as_json, returning a hash (AC#3)" do
            expect(render_loose.call(model_with_as_json)).to include_flight_row(
              class: :model,
              payload: hash_including("id" => 1, "name" => "Alice")
            )
          end

          it "calls on_as_json_warning with class name and attribute list (AC#1, #3)" do
            warnings = []
            b        = StubBundlerConfig.new
            Renderer.render(model_with_as_json, b,
                            strict_serialization: false,
                            on_as_json_warning: ->(cls, attrs) { warnings << [cls, attrs] })
            expect(warnings).to eq([["FakeModel", "id, name"]])
          end

          it "does NOT call on_as_json_warning when callback is nil (AC#3)" do
            expect { render_loose.call(model_with_as_json) }.not_to raise_error
          end
        end

        context "with strict_serialization: true" do
          let(:render_strict) do
            b = StubBundlerConfig.new
            ->(model) { Renderer.render(model, b, strict_serialization: true) }
          end

          it "raises SerializationError with Serializable hint (AC#2)" do
            expect { render_strict.call(model_with_as_json) }
              .to raise_error(Ruact::SerializationError, /FakeModel/)
            expect { render_strict.call(model_with_as_json) }
              .to raise_error(Ruact::SerializationError,
                              /include Ruact::Serializable or set strict_serialization: false/)
          end
        end

        context "with as_json returning non-Hash (e.g. array)" do
          let(:model_returning_array) do
            Class.new do
              def as_json
                [1, 2, 3]
              end

              def self.name
                "ArrayModel"
              end
            end.new
          end

          it "serializes the array without crashing" do
            b = StubBundlerConfig.new
            output = Renderer.render(model_returning_array, b, strict_serialization: false)
            expect(output).to include_flight_row(class: :model, payload: [1, 2, 3])
          end
        end

        context "with as_json returning self" do
          let(:model_returning_self) do
            Class.new do
              def as_json
                self
              end

              def self.name
                "SelfModel"
              end
            end.new
          end

          it "raises SerializationError about infinite recursion" do
            b = StubBundlerConfig.new
            expect { Renderer.render(model_returning_self, b, strict_serialization: false) }
              .to raise_error(Ruact::SerializationError, /infinite recursion/)
          end
        end

        # --- Story 7.7 regression suite — as_json returning self message shape ---
        #
        # The "with as_json returning self" context at :169 above asserts the error
        # class plus the substring "infinite recursion". That gate passes if the
        # message drifts to e.g. "infinite recursion detected" with no class name
        # and no actionable hint — the user reading a Sentry issue would not learn
        # which model misbehaved or how to fix it. The block below gates the full
        # message shape from gem/lib/ruact/flight/serializer.rb#serialize_as_json:
        # the offending class name + "Ruact::Serializable" + "rsc_props" must all
        # appear so the message remains debuggable in production.
        describe "edge cases (Story 7.7) — as_json returning self message shape", :story_7_7 do
          let(:self_returning_model) do
            Class.new do
              def as_json
                self
              end

              def self.name
                "SelfModel"
              end
            end.new
          end

          it "names the offending class and points the user at Ruact::Serializable + rsc_props" do
            b = StubBundlerConfig.new
            expect { Renderer.render(self_returning_model, b, strict_serialization: false) }
              .to raise_error(Ruact::SerializationError) do |error|
                expect(error.message).to include("SelfModel")
                expect(error.message).to include("Ruact::Serializable")
                expect(error.message).to include("rsc_props")
              end
          end
        end

        context "with as_json raising an exception" do
          let(:model_raising_error) do
            Class.new do
              def as_json
                raise "broken"
              end

              def self.name
                "BrokenModel"
              end
            end.new
          end

          it "wraps the exception in SerializationError" do
            b = StubBundlerConfig.new
            expect { Renderer.render(model_raising_error, b, strict_serialization: false) }
              .to raise_error(Ruact::SerializationError, /BrokenModel#as_json raised RuntimeError: broken/)
          end
        end

        context "without as_json method" do
          it "raises SerializationError regardless of strict_serialization (AC#4)" do
            b = StubBundlerConfig.new
            [true, false].each do |strict|
              expect { Renderer.render(model_without_as_json, b, strict_serialization: strict) }
                .to raise_error(Ruact::SerializationError, /include Ruact::Serializable/)
            end
          end
        end
      end

      # --- Story 2.3: Serializable serialization ---

      describe "Serializable serialization (Story 2.3)" do
        let(:serializable_obj) do
          Class.new do
            include Ruact::Serializable

            attr_reader :id, :title

            def initialize
              @id    = 1
              @title = "Hello"
            end

            def self.name
              "FakeSerializable"
            end

            rsc_props :id, :title
          end.new
        end

        it "serializes via rsc_serialize — only declared props (AC#1)" do
          expect(render.call(serializable_obj)).to include_flight_row(
            class: :model,
            payload: hash_including("id" => 1, "title" => "Hello")
          )
        end

        it "works with strict_serialization: true — Serializable bypasses strict gate (AC#1)" do
          b = StubBundlerConfig.new
          output = Renderer.render(serializable_obj, b, strict_serialization: true)
          expect(output).to include_flight_row(class: :model, payload: hash_including("id" => 1))
        end

        it "does NOT call on_as_json_warning (AC#3)" do
          warnings = []
          b = StubBundlerConfig.new
          Renderer.render(serializable_obj, b,
                          strict_serialization: false,
                          on_as_json_warning: ->(cls, attrs) { warnings << [cls, attrs] })
          expect(warnings).to be_empty
        end
      end

      # --- Fixture Contracts (AC#9) ---
      #
      # Fixture mode is the canonical guard for the Flight wire-format invariants
      # of every primitive type: byte-exact escape rules, scalar canonical bytes,
      # ordering. Story 7.6 deleted the duplicate literal-`eq` blocks that lived
      # at the top of this file; these fixture-mode blocks are now the single
      # source of truth for those invariants.

      describe "fixture contracts (AC#9)" do
        let(:fixture_render) { ->(model) { Renderer.render(model, ClientManifest.from_hash({})) } }

        it "nil serializes to fixture" do
          expect(fixture_render.call(nil)).to match_flight_fixture("nil")
        end

        it "true serializes to fixture" do
          expect(fixture_render.call(true)).to match_flight_fixture("boolean_true")
        end

        it "false serializes to fixture" do
          expect(fixture_render.call(false)).to match_flight_fixture("boolean_false")
        end

        it "plain string serializes to fixture" do
          expect(fixture_render.call("hello")).to match_flight_fixture("string_basic")
        end

        it "dollar-prefixed string serializes to fixture" do
          expect(fixture_render.call("$danger")).to match_flight_fixture("string_dollar_escape")
        end

        it "integer serializes to fixture" do
          expect(fixture_render.call(42)).to match_flight_fixture("number_integer")
        end

        it "float serializes to fixture" do
          expect(fixture_render.call(3.14)).to match_flight_fixture("number_float")
        end

        it "bigint (> MAX_SAFE_INTEGER) serializes to fixture as $n<decimal>" do
          expect(fixture_render.call(9_007_199_254_740_992)).to match_flight_fixture("bigint")
        end

        it "Float::NAN serializes to fixture as $NaN" do
          expect(fixture_render.call(Float::NAN)).to match_flight_fixture("nan")
        end

        it "Float::INFINITY serializes to fixture as $Infinity" do
          expect(fixture_render.call(Float::INFINITY)).to match_flight_fixture("infinity")
        end

        it "-Float::INFINITY serializes to fixture as $-Infinity" do
          expect(fixture_render.call(-Float::INFINITY)).to match_flight_fixture("negative_infinity")
        end

        it ":undefined serializes to fixture as $undefined" do
          expect(fixture_render.call(:undefined)).to match_flight_fixture("undefined")
        end

        it "mixed array serializes to fixture" do
          expect(fixture_render.call([1, "a", true, nil])).to match_flight_fixture("array")
        end

        it "hash with symbol keys serializes to fixture" do
          expect(fixture_render.call({ debug: true, count: 5, label: "x" })).to match_flight_fixture("hash")
        end
      end

      describe "client reference fixture contract (AC#3)" do
        let(:manifest_with_button) do
          ClientManifest.from_hash({
                                     "LikeButton" => {
                                       "id" => "/LikeButton.jsx",
                                       "name" => "LikeButton",
                                       "chunks" => ["/LikeButton.jsx"]
                                     }
                                   })
        end

        it "client reference element serializes to fixture (AC#3)" do
          ref = manifest_with_button.reference_for("LikeButton")
          el  = ReactElement.new(type: ref, props: {})
          expect(Renderer.render(el, manifest_with_button)).to match_flight_fixture("client_reference")
        end
      end

      describe "as_json object fixture contract (Story 2.2)" do
        let(:postcard_manifest) do
          ClientManifest.from_hash({
                                     "PostCard" => {
                                       "id" => "/PostCard.jsx",
                                       "name" => "PostCard",
                                       "chunks" => ["/PostCard.jsx"]
                                     }
                                   })
        end
        let(:as_json_obj) do
          Class.new do
            def as_json
              { "id" => 1, "title" => "Hello", "author" => "Alice", "likesCount" => 5 }
            end

            def self.name
              "Post"
            end
          end.new
        end

        it "component with as_json prop serializes to fixture" do
          ref = postcard_manifest.reference_for("PostCard")
          el  = ReactElement.new(type: ref, props: { post: as_json_obj })
          output = Renderer.render(el, postcard_manifest, strict_serialization: false)
          expect(output).to match_flight_fixture("as_json_object")
        end
      end

      describe "serializable object fixture contract (Story 2.3)" do
        let(:postcard_manifest_s) do
          ClientManifest.from_hash({
                                     "PostCard" => {
                                       "id" => "/PostCard.jsx",
                                       "name" => "PostCard",
                                       "chunks" => ["/PostCard.jsx"]
                                     }
                                   })
        end
        let(:serializable_obj) do
          Class.new do
            include Ruact::Serializable

            attr_reader :id, :title

            def initialize
              @id    = 1
              @title = "Hello"
            end

            def self.name
              "Post"
            end

            rsc_props :id, :title
          end.new
        end

        it "component with Serializable prop serializes to fixture (AC#4)" do
          ref = postcard_manifest_s.reference_for("PostCard")
          el  = ReactElement.new(type: ref, props: { post: serializable_obj })
          expect(Renderer.render(el, postcard_manifest_s)).to match_flight_fixture("serializable_object")
        end
      end

      describe "client component with props fixture contract (Story 2.1)" do
        let(:counter_manifest) do
          ClientManifest.from_hash({
                                     "CounterButton" => {
                                       "id" => "/CounterButton.jsx",
                                       "name" => "CounterButton",
                                       "chunks" => ["/CounterButton.jsx"]
                                     }
                                   })
        end

        it "client component with integer+string+boolean props serializes to fixture" do
          ref = counter_manifest.reference_for("CounterButton")
          el  = ReactElement.new(type: ref, props: { initialCount: 0, label: "Click me", disabled: false })
          expect(Renderer.render(el, counter_manifest)).to match_flight_fixture("client_component_with_props")
        end
      end
    end
  end
end
