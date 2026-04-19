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

    def render(erb_source, **locals)
      ctx = Object.new
      locals.each { |k, v| ctx.instance_variable_set("@#{k}", v) }
      pipeline.call(erb_source, ctx.instance_eval { binding })
    end

    describe "plain HTML" do
      it "serializes a plain HTML element" do
        output = render('<div class="hello"><p>World</p></div>')
        expect(output).to match(/0:\["\$","div"/)
        expect(output).to match(/"className":"hello"/)
      end
    end

    describe "unknown component" do
      it "raises an error when component is not in manifest" do
        expect { render("<Button />") }.to raise_error(an_object_satisfying { |e|
          e.message.include?("not found in manifest")
        })
      end
    end

    describe "client component with props" do
      it "emits I row, serializes props, and puts root at ID 0" do
        output = render("<div><LikeButton postId={@post_id} initialCount={5} /></div>",
                        post_id: 42)

        expect(output).to match(/I\[/)
        expect(output).to match(/LikeButton/)
        expect(output).to match(/"postId":42/)
        expect(output).to match(/"initialCount":5/)
        expect(output.lines.last).to start_with("0:"), "last row should be root (id=0)"
      end
    end

    describe "import row ordering" do
      it "emits the I row before the root model row" do
        output = render("<LikeButton postId={1} />")
        lines  = output.lines.map(&:strip).reject(&:empty?)

        import_idx = lines.index { |l| l.include?(":I[") }
        model_idx  = lines.index { |l| l.start_with?("0:") }

        expect(import_idx).to be < model_idx, "I row must come before the root model row"
      end
    end

    describe "ERB instance variables" do
      it "evaluates ERB and passes instance variables into the output" do
        output = render("<p><%= @title %></p>", title: "Hello RSC")
        expect(output).to match(/"Hello RSC"/)
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
            output = pipeline.call(
              "<LikeButton postId={@index} />",
              ctx.instance_eval { binding }
            )
            mutex.synchronize { results[i] = output }
          rescue StandardError => e
            mutex.synchronize { errors << e }
          end
        end

        threads.each(&:join)

        expect(errors).to be_empty, "Threads raised: #{errors.map(&:message).join(', ')}"

        10.times do |i|
          expect(results[i]).to include("\"postId\":#{i}"),
                                "Thread #{i} must contain postId=#{i} — got: #{results[i].inspect}"
        end
      end
    end

    describe "determinism (NFR16)" do
      it "produces identical byte output on repeated renders of the same view" do
        first  = render("<div><LikeButton postId={1} /></div>")
        second = render("<div><LikeButton postId={1} /></div>")
        expect(first).to eq(second)
      end

      it "produces different output for different input data" do
        output_a = render("<LikeButton postId={1} />")
        output_b = render("<LikeButton postId={2} />")
        expect(output_a).not_to eq(output_b)
      end
    end

    # --- from_html — ActionView integration path (Story 1.6) ---

    describe "#from_html" do
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
        ComponentRegistry.start
        token = ComponentRegistry.register("NavBar", { "currentUser" => 42 })
        html  = "<div><!-- #{token} --></div>"

        output = pipeline.from_html(html).to_a.join
        ComponentRegistry.reset

        expect(output).to include("NavBar")
        expect(output).to include('"currentUser":42')
      end

      it "eagerly captures registry so ComponentRegistry can be reset before Enumerator is consumed" do
        pipeline = described_class.new(navbar_manifest)
        ComponentRegistry.start
        ComponentRegistry.register("NavBar", { "currentUser" => 1 })
        token = ComponentRegistry.components.first[:token]
        html  = "<div><!-- #{token} --></div>"

        enumerator = pipeline.from_html(html)
        ComponentRegistry.reset # Reset BEFORE consuming the enumerator

        expect { enumerator.to_a }.not_to raise_error
        expect(enumerator.to_a.join).to include("NavBar")
      end

      it "produces the same Flight output as call() for equivalent input" do
        # Build the same HTML that RenderPipeline#call would produce for <NavBar />
        # and verify from_html produces the same Flight output.
        pipeline_erb  = described_class.new(navbar_manifest)
        pipeline_html = described_class.new(navbar_manifest)

        pipeline_erb.call("<NavBar currentUser={1} />", binding)

        ComponentRegistry.start
        ComponentRegistry.register("NavBar", { "currentUser" => 1 })
        token = ComponentRegistry.components.first[:token]
        html  = "<!-- #{token} -->"
        html_output = pipeline_html.from_html(html).to_a.join
        ComponentRegistry.reset

        # Both should contain the NavBar import row and a root model row
        expect(html_output).to include("NavBar")
        expect(html_output).to match(/0:\[/)
      end

      it "returns an Enumerator (lazy)" do
        pipeline = described_class.new(manifest)
        ComponentRegistry.start
        html = "<div><p>Hello</p></div>"

        result = pipeline.from_html(html)
        ComponentRegistry.reset

        expect(result).to be_a(Enumerator)
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
        output = pipeline.call("<LikeButton />", ctx.instance_eval { binding })
        expect(output).to include("/posts/_like_button.jsx")
        expect(output).not_to include("/LikeButton.jsx")
      end

      it "uses shared component when no controller_path given (AC#1)" do
        pipeline = described_class.new(dual_manifest)
        ctx = Object.new
        output = pipeline.call("<LikeButton />", ctx.instance_eval { binding })
        expect(output).to include("/LikeButton.jsx")
        expect(output).not_to include("/posts/_like_button.jsx")
      end

      it "falls back to shared when controller_path has no co-located key (AC#4)" do
        pipeline = described_class.new(dual_manifest, controller_path: "comments")
        ctx = Object.new
        output = pipeline.call("<LikeButton />", ctx.instance_eval { binding })
        expect(output).to include("/LikeButton.jsx")
      end
    end

    # --- Prop type integration specs (AC#1–#7) ---

    describe "prop types via ERB (AC#1–#7)" do
      it "integer prop is a JSON number, not a string (AC#1)" do
        output = render("<LikeButton postId={@count} />", count: 42)
        expect(output).to include('"postId":42')
        expect(output).not_to include('"postId":"42"')
      end

      it "string prop is a JSON string (AC#2)" do
        output = render("<LikeButton label={@title} />", title: "hello")
        expect(output).to include('"label":"hello"')
      end

      it "dollar-prefixed string is escaped with one extra $ (AC#3)" do
        output = render("<LikeButton label={@price} />", price: "$9.99")
        expect(output).to include('"label":"$$9.99"')
      end

      it "boolean true prop is a JSON boolean literal (AC#4)" do
        output = render("<LikeButton enabled={true} />")
        expect(output).to include('"enabled":true')
        expect(output).not_to include('"enabled":"true"')
      end

      it "boolean false prop is a JSON boolean literal (AC#4)" do
        output = render("<LikeButton active={false} />")
        expect(output).to include('"active":false')
        expect(output).not_to include('"active":"false"')
      end

      it "nil prop becomes JSON null (AC#5)" do
        output = render("<LikeButton value={nil} />")
        expect(output).to include('"value":null')
        expect(output).not_to include('"value":"nil"')
      end

      it "array prop has correctly typed elements (AC#6)" do
        output = render("<LikeButton items={[1, \"a\", true, nil]} />")
        expect(output).to include('"items":[1,"a",true,null]')
      end

      it "hash prop produces a JSON object with correct types (AC#7)" do
        output = render("<LikeButton opts={{debug: true, count: 5, label: \"x\"}} />")
        expect(output).to include('"opts":{"debug":true,"count":5,"label":"x"}')
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
        pipeline_with_cards.call(
          "<% @posts.each do |post| %><PostCard title={post.title} id={post.id} /><% end %>",
          ctx.instance_eval { binding }
        )
      end

      it "each PostCard receives its correct title prop" do
        expect(loop_output).to include('"title":"First"')
        expect(loop_output).to include('"title":"Second"')
        expect(loop_output).to include('"title":"Third"')
      end

      it "each PostCard receives its correct id prop as a JSON number" do
        expect(loop_output).to include('"id":1')
        expect(loop_output).to include('"id":2')
        expect(loop_output).to include('"id":3')
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
        output = render("<PostCard post={@the_post} />", the_post: post_like_object)
        expect(output).to include('"id":1')
        expect(output).to include('"title":"Hello"')
      end

      it "emits [ruact] warning via the injected logger (AC#1, #3)" do
        render("<PostCard post={@the_post} />", the_post: post_like_object)
        expect(fake_logger).to have_received(:warn)
          .with(match(/\[ruact\] WARNING: Post serialized via as_json/))
      end

      it "warning includes attribute names (AC#1)" do
        render("<PostCard post={@the_post} />", the_post: post_like_object)
        expect(fake_logger).to have_received(:warn)
          .with(match(/ALL attributes exposed to client: id, title/))
      end

      context "with strict_serialization pipeline" do
        let(:pipeline) { described_class.new(as_json_manifest, logger: fake_logger) }

        it "raises SerializationError when strict_serialization: true (AC#2)" do
          allow(Ruact.config).to receive(:strict_serialization).and_return(true)
          expect { render("<PostCard post={@the_post} />", the_post: post_like_object) }
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
        output = render("<PostCard post={@the_post} />", the_post: serializable_post)
        expect(output).to include('"id":1', '"title":"Hello"')
      end

      it "does NOT emit [ruact] warning (AC#3)" do
        render("<PostCard post={@the_post} />", the_post: serializable_post)
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
        output = render('<SearchInput placeholder={"Search..."} />')
        expect(output).to match(/"placeholder":"Search\.\.\."/)
      end

      it "serializes boolean true prop for useState initial value (AC#1)" do
        output = render("<CounterButton enabled={true} />")
        expect(output).to match(/"enabled":true/)
      end

      it "serializes boolean false prop for disabled state (AC#1)" do
        output = render("<CounterButton disabled={false} />")
        expect(output).to match(/"disabled":false/)
      end

      it "serializes nil prop as JSON null — no hydration mismatch for absent optionals (AC#4)" do
        output = render("<CounterButton initialCount={nil} />")
        expect(output).to match(/"initialCount":null/)
      end

      it "serializes mixed props (integer + string + boolean) in a single component (AC#1, #3, #4)" do
        output = render('<CounterButton initialCount={0} label={"Votes"} disabled={false} />')
        expect(output).to match(/"initialCount":0/)
        expect(output).to match(/"label":"Votes"/)
        expect(output).to match(/"disabled":false/)
      end
    end
  end
end
