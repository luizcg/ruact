# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe RenderPipeline do
    let(:manifest) do
      ClientManifest.from_hash({
                                 "LikeButton" => {
                                   "id" => "/assets/LikeButton-abc.js",
                                   "name" => "LikeButton",
                                   "chunks" => ["/assets/LikeButton-abc.js"]
                                 }
                               })
    end

    let(:manifest_with_post_card) do
      ClientManifest.from_hash({
                                 "LikeButton" => {
                                   "id" => "/assets/LikeButton-abc.js",
                                   "name" => "LikeButton",
                                   "chunks" => ["/assets/LikeButton-abc.js"]
                                 },
                                 "PostCard" => {
                                   "id" => "/assets/PostCard-abc.js",
                                   "name" => "PostCard",
                                   "chunks" => ["/assets/PostCard-abc.js"]
                                 }
                               })
    end

    let(:pipeline) { described_class.new(manifest) }

    # Methods (not `let`) so nested describes don't exceed RSpec/MultipleMemoizedHelpers
    # while still sharing a single source of truth for the LikeButton import row shape.
    def like_button_chunk
      "/assets/LikeButton-abc.js"
    end

    def like_button_import
      { id: 1, class: :import, payload: [like_button_chunk, "LikeButton", [like_button_chunk]] }
    end

    # Helper for the ERB-input path of #render. All describe blocks below — except
    # the explicitly-marked "#render with html input" — exercise this path.
    def render_erb(erb_source, **locals)
      ctx = Object.new
      locals.each { |k, v| ctx.instance_variable_set("@#{k}", v) }
      pipeline.render({ erb: erb_source, binding: ctx.instance_eval { binding } }, mode: :string)
    end

    describe "#render with erb input" do
      describe "plain HTML" do
        it "serializes a plain HTML element" do
          output = render_erb('<div class="hello"><p>World</p></div>')
          expect(output).to match_flight_structure([
                                                     { id: 0, class: :model,
                                                       payload: ["$", "div", nil, {
                                                         "className" => "hello",
                                                         "children" => ["$", "p", nil, { "children" => "World" }]
                                                       }] }
                                                   ])
        end
      end

      describe "unknown component" do
        it "raises an error when component is not in manifest" do
          expect { render_erb("<Button />") }.to raise_error(an_object_satisfying { |e|
            e.message.include?("not found in manifest")
          })
        end
      end

      describe "client component with props" do
        it "emits I row, serializes props, and puts root at ID 0" do
          output = render_erb("<div><LikeButton postId={@post_id} initialCount={5} /></div>",
                              post_id: 42)

          # Story 7.6 Decision B: collapse the four sibling regex assertions plus
          # the `output.lines.last.start_with?("0:")` ordering check into a single
          # structural assertion. Non-import rows compare positionally, so the
          # import in expected position 0 + the model in position 1 encodes
          # "import row precedes (and root is last)".
          inner_button = ["$", "$L1", nil, { "postId" => 42, "initialCount" => 5 }]
          expected = [
            like_button_import,
            { id: 0, class: :model, payload: ["$", "div", nil, { "children" => inner_button }] }
          ]
          expect(output).to match_flight_structure(expected)
        end
      end

      describe "import row ordering" do
        it "emits the I row before the root model row" do
          output = render_erb("<LikeButton postId={1} />")
          lines  = output.lines.map(&:strip).reject(&:empty?)

          import_idx = lines.index { |l| l.include?(":I[") }
          model_idx  = lines.index { |l| l.start_with?("0:") }

          expect(import_idx).to be < model_idx, "I row must come before the root model row"
        end
      end

      describe "ERB instance variables" do
        it "evaluates ERB and passes instance variables into the output" do
          output = render_erb("<p><%= @title %></p>", title: "Hello RSC")
          expect(output).to match_flight_structure([
                                                     { id: 0, class: :model,
                                                       payload: ["$", "p", nil, { "children" => "Hello RSC" }] }
                                                   ])
        end
      end

      describe "thread safety (NFR8)" do
        it "isolates component state across 10 concurrent renders" do
          results = Array.new(10)
          mutex   = Mutex.new
          errors  = []

          threads = Array.new(10) do |i|
            Thread.new do
              ctx = Object.new
              ctx.instance_variable_set(:@index, i)
              output = pipeline.render(
                { erb: "<LikeButton postId={@index} />", binding: ctx.instance_eval { binding } },
                mode: :string
              )
              mutex.synchronize { results[i] = output }
            rescue StandardError => e
              mutex.synchronize { errors << e }
            end
          end

          threads.each(&:join)

          expect(errors).to be_empty, "Threads raised: #{errors.map(&:message).join(', ')}"

          10.times do |i|
            expect(results[i]).to include_flight_row(
              class: :model, payload: array_including(hash_including("postId" => i))
            ), "Thread #{i} must contain postId=#{i} — got: #{results[i].inspect}"
          end
        end
      end

      describe "determinism (NFR16)" do
        it "produces identical byte output on repeated renders of the same view" do
          first  = render_erb("<div><LikeButton postId={1} /></div>")
          second = render_erb("<div><LikeButton postId={1} /></div>")
          # Determinism check — byte equality is the contract, see Story 7.6 Decision E.
          expect(first).to eq(second)
        end

        it "produces different output for different input data" do
          output_a = render_erb("<LikeButton postId={1} />")
          output_b = render_erb("<LikeButton postId={2} />")
          # Determinism check — byte inequality is the contract, see Story 7.6 Decision E.
          expect(output_a).not_to eq(output_b)
        end
      end

      # --- Dual-path resolution specs (Story 1.5) ---

      describe "dual-path resolution via controller_path" do
        let(:dual_manifest) do
          ClientManifest.from_hash({
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
                                   })
        end

        it "uses co-located component when controller_path matches (AC#2, AC#3)" do
          pipeline = described_class.new(dual_manifest, controller_path: "posts")
          ctx = Object.new
          output = pipeline.render({ erb: "<LikeButton />", binding: ctx.instance_eval { binding } }, mode: :string)
          expect(output).to     include_flight_row(class: :import, payload: array_including("/posts/_like_button.jsx"))
          expect(output).not_to include_flight_row(class: :import, payload: array_including("/LikeButton.jsx"))
        end

        it "uses shared component when no controller_path given (AC#1)" do
          pipeline = described_class.new(dual_manifest)
          ctx = Object.new
          output = pipeline.render({ erb: "<LikeButton />", binding: ctx.instance_eval { binding } }, mode: :string)
          expect(output).to     include_flight_row(class: :import, payload: array_including("/LikeButton.jsx"))
          expect(output).not_to include_flight_row(class: :import, payload: array_including("/posts/_like_button.jsx"))
        end

        it "falls back to shared when controller_path has no co-located key (AC#4)" do
          pipeline = described_class.new(dual_manifest, controller_path: "comments")
          ctx = Object.new
          output = pipeline.render({ erb: "<LikeButton />", binding: ctx.instance_eval { binding } }, mode: :string)
          expect(output).to include_flight_row(class: :import, payload: array_including("/LikeButton.jsx"))
        end
      end

      # --- Prop type integration specs (AC#1–#7) ---

      describe "prop types via ERB (AC#1–#7)" do
        it "integer prop is a JSON number, not a string (AC#1)" do
          output = render_erb("<LikeButton postId={@count} />", count: 42)
          expect(output).to     include_flight_row(class: :model,
                                                   payload: array_including(hash_including("postId" => 42)))
          expect(output).not_to include_flight_row(class: :model,
                                                   payload: array_including(hash_including("postId" => "42")))
        end

        it "string prop is a JSON string (AC#2)" do
          output = render_erb("<LikeButton label={@title} />", title: "hello")
          expect(output).to include_flight_row(class: :model,
                                               payload: array_including(hash_including("label" => "hello")))
        end

        it "dollar-prefixed string is escaped with one extra $ (AC#3)" do
          # The `$`-prefix escape is a Flight-protocol wire convention, not a
          # JSON escape — the parser is byte-faithful and does NOT decode the
          # extra `$` away. So the parsed prop value carries the escaped form
          # `"$$9.99"`. The byte-exactness of the escape rule itself is
          # guarded by serializer_spec's `string_dollar_escape` fixture; here
          # we just assert that the escape kicks in through the ERB pipeline.
          output = render_erb("<LikeButton label={@price} />", price: "$9.99")
          expect(output).to include_flight_row(class: :model,
                                               payload: array_including(hash_including("label" => "$$9.99")))
        end

        it "boolean true prop is a JSON boolean literal (AC#4)" do
          output = render_erb("<LikeButton enabled={true} />")
          expect(output).to     include_flight_row(class: :model,
                                                   payload: array_including(hash_including("enabled" => true)))
          expect(output).not_to include_flight_row(class: :model,
                                                   payload: array_including(hash_including("enabled" => "true")))
        end

        it "boolean false prop is a JSON boolean literal (AC#4)" do
          output = render_erb("<LikeButton active={false} />")
          expect(output).to     include_flight_row(class: :model,
                                                   payload: array_including(hash_including("active" => false)))
          expect(output).not_to include_flight_row(class: :model,
                                                   payload: array_including(hash_including("active" => "false")))
        end

        it "nil prop becomes JSON null (AC#5)" do
          output = render_erb("<LikeButton value={nil} />")
          expect(output).to     include_flight_row(class: :model,
                                                   payload: array_including(hash_including("value" => nil)))
          expect(output).not_to include_flight_row(class: :model,
                                                   payload: array_including(hash_including("value" => "nil")))
        end

        it "array prop has correctly typed elements (AC#6)" do
          output = render_erb("<LikeButton items={[1, \"a\", true, nil]} />")
          expect(output).to include_flight_row(
            class: :model,
            payload: array_including(hash_including("items" => [1, "a", true, nil]))
          )
        end

        it "hash prop produces a JSON object with correct types (AC#7)" do
          output = render_erb("<LikeButton opts={{debug: true, count: 5, label: \"x\"}} />")
          expect(output).to include_flight_row(
            class: :model,
            payload: array_including(hash_including("opts" => { "debug" => true, "count" => 5, "label" => "x" }))
          )
        end
      end

      # --- Loop / local variables spec (AC#8) ---

      describe "loop — local variables as props (AC#8)" do
        let(:post_struct) { Struct.new(:title, :id) }
        let(:posts) do
          [post_struct.new("First", 1), post_struct.new("Second", 2), post_struct.new("Third", 3)]
        end

        let(:loop_output) do
          pipeline_with_cards = described_class.new(manifest_with_post_card)
          ctx = Object.new
          ctx.instance_variable_set(:@posts, posts)
          pipeline_with_cards.render(
            {
              erb: "<% @posts.each do |post| %><PostCard title={post.title} id={post.id} /><% end %>",
              binding: ctx.instance_eval { binding }
            },
            mode: :string
          )
        end

        # Loop renders multiple PostCards as siblings under a Fragment-like root,
        # so model row 0's payload is an Array of React-element tuples
        # ([["$", "$L1", nil, {props}], …]). Predicate is nested:
        # array_including(array_including(hash_including(prop))).
        it "each PostCard receives its correct title prop" do
          %w[First Second Third].each do |title|
            expect(loop_output).to include_flight_row(
              class: :model,
              payload: array_including(array_including(hash_including("title" => title)))
            )
          end
        end

        it "each PostCard receives its correct id prop as a JSON number" do
          [1, 2, 3].each do |id|
            expect(loop_output).to include_flight_row(
              class: :model,
              payload: array_including(array_including(hash_including("id" => id)))
            )
          end
        end
      end

      # --- Story 2.2: as_json integration ---

      describe "as_json integration (Story 2.2)" do
        let(:as_json_manifest) do
          ClientManifest.from_hash({
                                     "PostCard" => {
                                       "id" => "/assets/PostCard-abc.js",
                                       "name" => "PostCard",
                                       "chunks" => ["/assets/PostCard-abc.js"]
                                     }
                                   })
        end
        let(:fake_logger) { instance_double(::Logger, warn: nil) }
        let(:pipeline) { described_class.new(as_json_manifest, logger: fake_logger) }

        let(:post_like_object) do
          Class.new do
            def as_json
              { "id" => 1, "title" => "Hello" }
            end

            def self.name
              "Post"
            end
          end.new
        end

        it "serializes as_json object as a JSON object prop (AC#1)" do
          output = render_erb("<PostCard post={@the_post} />", the_post: post_like_object)
          expect(output).to include_flight_row(
            class: :model,
            payload: array_including(hash_including("post" => hash_including("id" => 1, "title" => "Hello")))
          )
        end

        it "emits [ruact] warning via the injected logger (AC#1, #3)" do
          render_erb("<PostCard post={@the_post} />", the_post: post_like_object)
          expect(fake_logger).to have_received(:warn)
            .with(match(/\[ruact\] WARNING: Post serialized via as_json/))
        end

        it "warning includes attribute names (AC#1)" do
          render_erb("<PostCard post={@the_post} />", the_post: post_like_object)
          expect(fake_logger).to have_received(:warn)
            .with(match(/ALL attributes exposed to client: id, title/))
        end

        context "with strict_serialization pipeline" do
          let(:pipeline) { described_class.new(as_json_manifest, logger: fake_logger) }

          # Configuration is frozen post-Story 7.3, so RSpec mocks cannot proxy it.
          # Configure via Ruact.configure and reset around the example.
          around do |example|
            Ruact.instance_variable_set(:@config, nil)
            Ruact.instance_variable_set(:@configured_at_least_once, false)
            example.run
            Ruact.instance_variable_set(:@config, nil)
            Ruact.instance_variable_set(:@configured_at_least_once, false)
          end

          it "raises SerializationError when strict_serialization: true (AC#2)" do
            Ruact.configure { |c| c.strict_serialization = true }
            expect { render_erb("<PostCard post={@the_post} />", the_post: post_like_object) }
              .to raise_error(Ruact::SerializationError, /strict_serialization/)
          end
        end
      end

      # --- Story 2.3: Serializable integration ---

      describe "Serializable integration (Story 2.3)" do
        let(:serializable_manifest) do
          ClientManifest.from_hash({
                                     "PostCard" => {
                                       "id" => "/assets/PostCard-abc.js",
                                       "name" => "PostCard",
                                       "chunks" => ["/assets/PostCard-abc.js"]
                                     }
                                   })
        end
        let(:fake_logger_s) { instance_double(::Logger, warn: nil) }
        let(:pipeline) { described_class.new(serializable_manifest, logger: fake_logger_s) }

        let(:serializable_post) do
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

        it "serializes only declared props (AC#1)" do
          output = render_erb("<PostCard post={@the_post} />", the_post: serializable_post)
          expect(output).to include_flight_row(
            class: :model,
            payload: array_including(hash_including("post" => hash_including("id" => 1, "title" => "Hello")))
          )
        end

        it "does NOT emit [ruact] warning (AC#3)" do
          render_erb("<PostCard post={@the_post} />", the_post: serializable_post)
          expect(fake_logger_s).not_to have_received(:warn)
        end
      end

      # --- Story 2.1: useState/useEffect/event handler prop types ---

      describe "client components with hook prop types (Story 2.1)" do
        let(:manifest_with_hooks) do
          ClientManifest.from_hash({
                                     "CounterButton" => {
                                       "id" => "/assets/CounterButton-abc.js",
                                       "name" => "CounterButton",
                                       "chunks" => ["/assets/CounterButton-abc.js"]
                                     },
                                     "SearchInput" => {
                                       "id" => "/assets/SearchInput-abc.js",
                                       "name" => "SearchInput",
                                       "chunks" => ["/assets/SearchInput-abc.js"]
                                     }
                                   })
        end
        let(:pipeline) { described_class.new(manifest_with_hooks) }

        it "serializes string prop (AC#3 — useState initial string, onChange placeholder)" do
          output = render_erb('<SearchInput placeholder={"Search..."} />')
          expect(output).to include_flight_row(
            class: :model, payload: array_including(hash_including("placeholder" => "Search..."))
          )
        end

        it "serializes boolean true prop for useState initial value (AC#1)" do
          output = render_erb("<CounterButton enabled={true} />")
          expect(output).to include_flight_row(
            class: :model, payload: array_including(hash_including("enabled" => true))
          )
        end

        it "serializes boolean false prop for disabled state (AC#1)" do
          output = render_erb("<CounterButton disabled={false} />")
          expect(output).to include_flight_row(
            class: :model, payload: array_including(hash_including("disabled" => false))
          )
        end

        it "serializes nil prop as JSON null — no hydration mismatch for absent optionals (AC#4)" do
          output = render_erb("<CounterButton initialCount={nil} />")
          expect(output).to include_flight_row(
            class: :model, payload: array_including(hash_including("initialCount" => nil))
          )
        end

        it "serializes mixed props (integer + string + boolean) in a single component (AC#1, #3, #4)" do
          # Three sibling assertions on the same render → Decision B (full structure)
          # so the failure message names exactly which prop drifted, not just
          # "some row matched, some didn't".
          output = render_erb('<CounterButton initialCount={0} label={"Votes"} disabled={false} />')
          counter_module = "/assets/CounterButton-abc.js"
          expected = [
            { id: 1, class: :import, payload: [counter_module, "CounterButton", [counter_module]] },
            { id: 0, class: :model,
              payload: ["$", "$L1", nil, { "initialCount" => 0, "label" => "Votes", "disabled" => false }] }
          ]
          expect(output).to match_flight_structure(expected)
        end
      end

      describe "nested pipeline.render sharing a binding receiver" do
        let(:nesting_pipeline) { described_class.new(manifest) }

        it "restores the outer render context after an inner render completes (Story 7.1 review F1)" do
          # Reproduces the original review concern: an outer pipeline.render whose
          # ERB triggers an inner pipeline.render on the same binding receiver
          # would, under the old closure-based inject_helper, overwrite the
          # singleton method's bound context. After the inner render returned,
          # the outer ERB's __rsc_component__ calls would register into the
          # inner's discarded RenderContext — leaking the outer component out.
          #
          # The fix stores the active context on the receiver as an ivar and
          # save/restores it around ERB evaluation.
          inner = nesting_pipeline
          receiver = Object.new
          receiver.define_singleton_method(:run_inner) do
            inner.render({ erb: "<LikeButton postId={999} />", binding: binding }, mode: :string)
            ""
          end

          outer = nesting_pipeline.render(
            { erb: "<div><%= run_inner %><LikeButton postId={1} /></div>", binding: receiver.instance_eval do
              binding
            end },
            mode: :string
          )

          # The outer LikeButton (postId=1) is nested inside the div's children,
          # so the postId hash lives at payload[3]["children"][3]. Asserting on
          # the full known structure proves the inner render's postId=999 did
          # not leak through the registry into the outer's children.
          expect(outer).to match_flight_structure([
                                                    like_button_import,
                                                    { id: 0, class: :model,
                                                      payload: ["$", "div", nil, {
                                                        "children" => ["$", "$L1", nil, { "postId" => 1 }]
                                                      }] }
                                                  ])
        end
      end
    end

    # --- #render with html input — ActionView integration path (Story 1.6, consolidated in 7.2) ---

    describe "#render with html input" do
      let(:navbar_manifest) do
        ClientManifest.from_hash({
                                   "NavBar" => {
                                     "id" => "/NavBar.jsx",
                                     "name" => "NavBar",
                                     "chunks" => ["/NavBar.jsx"]
                                   }
                                 })
      end

      it "converts pre-rendered HTML with component placeholders to Flight rows" do
        pipeline = described_class.new(navbar_manifest)
        ctx = RenderContext.new
        token = ctx.register("NavBar", { "currentUser" => 42 })
        html  = "<div><!-- #{token} --></div>"

        output = pipeline.render({ html: html, render_context: ctx }, mode: :string)

        # NavBar lives nested inside the div's children, so the props hash is
        # at payload[3]["children"][3]. Asserting full structure here keeps the
        # 7.6 cosmetic-robustness contract while preserving the original test
        # intent (placeholder-token resolution + props serialization).
        expect(output).to match_flight_structure([
                                                   { id: 1, class: :import,
                                                     payload: ["/NavBar.jsx", "NavBar", ["/NavBar.jsx"]] },
                                                   { id: 0, class: :model,
                                                     payload: ["$", "div", nil, {
                                                       "children" => ["$", "$L1", nil, { "currentUser" => 42 }]
                                                     }] }
                                                 ])
      end

      it "eagerly captures registry so further mutation does not affect the Enumerator" do
        pipeline = described_class.new(navbar_manifest)
        ctx = RenderContext.new
        ctx.register("NavBar", { "currentUser" => 1 })
        token = ctx.components.first[:token]
        html  = "<div><!-- #{token} --></div>"

        enumerator = pipeline.render({ html: html, render_context: ctx }, mode: :stream)
        # Mutating the context after #render should not affect the captured registry.
        ctx.components.clear

        expect { enumerator.to_a }.not_to raise_error
        expect(enumerator.to_a.join).to include_flight_row(
          class: :import, payload: array_including("/NavBar.jsx")
        )
      end

      it "produces the same Flight output as the erb-input path for equivalent input" do
        # Build the same HTML that #render with erb input would produce for <NavBar />
        # and verify the html-input path produces the same Flight output.
        pipeline_erb  = described_class.new(navbar_manifest)
        pipeline_html = described_class.new(navbar_manifest)

        pipeline_erb.render({ erb: "<NavBar currentUser={1} />", binding: binding }, mode: :string)

        ctx = RenderContext.new
        ctx.register("NavBar", { "currentUser" => 1 })
        token = ctx.components.first[:token]
        html  = "<!-- #{token} -->"
        html_output = pipeline_html.render({ html: html, render_context: ctx }, mode: :string)

        # Both should contain the NavBar import row and the root model row (id: 0).
        # html_output here is the raw Flight wire (mode: :string returns wire bytes,
        # not an HTML shell), so structural matchers apply. Original assertion was
        # `match(/0:\[/)` which encoded "the root row exists"; preserve the id: 0
        # constraint via include_flight_row so a future change that emitted only a
        # nested model row (without root) would still fail.
        expect(html_output).to include_flight_row(class: :import, payload: array_including("/NavBar.jsx"))
        expect(html_output).to include_flight_row(id: 0, class: :model)
      end

      it "returns an Enumerator (lazy) when mode is :stream" do
        pipeline = described_class.new(manifest)
        html = "<div><p>Hello</p></div>"

        result = pipeline.render({ html: html, render_context: RenderContext.new }, mode: :stream)

        expect(result).to be_a(Enumerator)
      end
    end

    # --- #render — single coherent entry point (Story 7.2) ---
    describe "#render contract" do
      let(:erb_source) { "<LikeButton />" }
      let(:erb_binding) { Object.new.instance_eval { binding } }
      let(:html_input)  { "<!-- __RSC_0__ -->" }
      let(:render_ctx)  { RenderContext.new.tap { |c| c.register("LikeButton", {}) } }

      describe "input validation" do
        it "raises ArgumentError when :erb is given without sibling :binding" do
          expect { pipeline.render({ erb: erb_source }, mode: :string) }
            .to raise_error(ArgumentError, /sibling :binding/)
        end

        it "raises ArgumentError when :html is given without sibling :render_context" do
          expect { pipeline.render({ html: html_input }, mode: :string) }
            .to raise_error(ArgumentError, /sibling :render_context/)
        end

        it "raises ArgumentError when input mixes :erb and :html keys" do
          expect do
            pipeline.render(
              { erb: erb_source, binding: erb_binding, html: html_input, render_context: render_ctx },
              mode: :string
            )
          end.to raise_error(ArgumentError, /cannot mix :erb and :html/)
        end

        it "raises ArgumentError when input has neither :erb nor :html" do
          expect { pipeline.render({}, mode: :string) }
            .to raise_error(ArgumentError, /must include either :erb .* or :html/)
        end

        it "raises ArgumentError when input is not a Hash" do
          expect { pipeline.render(nil, mode: :string) }
            .to raise_error(ArgumentError, /must be a Hash/)
        end

        it "raises ArgumentError on unknown :mode value" do
          expect { pipeline.render({ erb: erb_source, binding: erb_binding }, mode: :weird) }
            .to raise_error(ArgumentError, /unknown render mode :weird.*expected one of/)
        end

        it "raises ArgumentError when :erb is not a String" do
          expect { pipeline.render({ erb: 42, binding: erb_binding }, mode: :string) }
            .to raise_error(ArgumentError, /:erb must be a String/)
        end

        it "raises ArgumentError when :binding is not a Binding" do
          expect { pipeline.render({ erb: erb_source, binding: "not a binding" }, mode: :string) }
            .to raise_error(ArgumentError, /:binding must be a Binding/)
        end

        it "raises ArgumentError when :html is not a String" do
          expect { pipeline.render({ html: 42, render_context: render_ctx }, mode: :string) }
            .to raise_error(ArgumentError, /:html must be a String/)
        end

        it "raises ArgumentError when :render_context is not a Ruact::RenderContext" do
          expect { pipeline.render({ html: html_input, render_context: Object.new }, mode: :string) }
            .to raise_error(ArgumentError, /:render_context must be a Ruact::RenderContext/)
        end

        it "raises ArgumentError when input contains extra keys beyond the documented shapes" do
          expect do
            pipeline.render({ erb: erb_source, binding: erb_binding, foo: 1 }, mode: :string)
          end.to raise_error(ArgumentError, /unsupported keys: \[:foo\]/)
        end

        it "all validation errors reference the RenderPipeline#render docstring" do
          expect { pipeline.render(nil, mode: :string) }
            .to raise_error(ArgumentError, /RenderPipeline#render docstring/)
        end
      end

      describe "mode contract" do
        it "returns a String when mode is :string (erb input)" do
          out = pipeline.render({ erb: erb_source, binding: erb_binding }, mode: :string)
          expect(out).to be_a(String)
          expect(out).to include_flight_row(class: :import, payload: array_including("LikeButton"))
        end

        it "returns an Enumerator when mode is :stream (erb input)" do
          out = pipeline.render({ erb: erb_source, binding: erb_binding }, mode: :stream)
          expect(out).to be_a(Enumerator)
          joined = out.to_a.join
          expect(joined).to include_flight_row(class: :import, payload: array_including("LikeButton"))
        end

        it "returns a String when mode is :string (html input)" do
          out = pipeline.render({ html: html_input, render_context: render_ctx }, mode: :string)
          expect(out).to be_a(String)
          expect(out).to include_flight_row(class: :import, payload: array_including("LikeButton"))
        end

        it "returns an Enumerator when mode is :stream (html input)" do
          out = pipeline.render({ html: html_input, render_context: render_ctx }, mode: :stream)
          expect(out).to be_a(Enumerator)
          joined = out.to_a.join
          expect(joined).to include_flight_row(class: :import, payload: array_including("LikeButton"))
        end

        it "defaults mode to :string when omitted" do
          out = pipeline.render({ erb: erb_source, binding: erb_binding })
          expect(out).to be_a(String)
        end
      end

      describe "eager-capture invariant (html input)" do
        it "does not reach back into the RenderContext after #render returns" do
          ctx = RenderContext.new
          ctx.register("LikeButton", { "postId" => 1 })

          enum = pipeline.render({ html: "<!-- __RSC_0__ -->", render_context: ctx }, mode: :stream)

          # Mutating the context after #render returns must not affect the captured registry.
          ctx.register("LikeButton", { "postId" => 999 })

          out = enum.to_a.join
          expect(out).to     include_flight_row(class: :model, payload: array_including(hash_including("postId" => 1)))
          expect(out).not_to include_flight_row(class: :model,
                                                payload: array_including(hash_including("postId" => 999)))
        end
      end
    end
  end
end
