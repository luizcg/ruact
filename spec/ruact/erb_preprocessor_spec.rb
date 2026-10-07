# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ErbPreprocessor do
    subject(:transform) { ->(source) { described_class.transform(source) } }

    # Story 18-2 — the preprocessor checks component names against the
    # loaded manifest. A spec that boots a Rails app leaves one behind; these
    # examples are about the transform, so they run without one.
    around do |example|
      saved = Ruact.manifest
      Ruact.manifest = nil
      example.run
    ensure
      Ruact.manifest = saved
    end

    # A JSX hand writes `title="Hello"`; the preprocessor read only `{…}` and
    # dropped every other attribute without a word.
    describe "attribute forms, as JSX writes them" do
      def props_of(source)
        described_class.transform(source, registry: nil)[/__ruact_component__\("\w+", (.*)\) %>/, 1]
      end

      it "passes a quoted attribute as a string, double or single quotes" do
        expect(props_of(%(<PostCard title="Hello" subtitle='World' />)))
          .to eq(%({ "title" => "Hello", "subtitle" => "World" }))
      end

      it "passes a bare attribute as true" do
        expect(props_of(%(<Toggle disabled on={false} />))).to eq(%({ "disabled" => true, "on" => false }))
      end

      it "keeps hyphenated names and Ruby expressions" do
        expect(props_of(%(<Row data-id="7" count={@items.size} />)))
          .to eq(%({ "data-id" => "7", "count" => @items.size }))
      end

      it "does not let a quoted value run Ruby" do
        expect(props_of(%(<PostCard title="\#{system('x')}" />))).to eq(%({ "title" => "\\\#{system('x')}" }))
      end

      it "refuses ERB inside a quoted attribute, naming the fix" do
        expect { described_class.transform(%(<PostCard title="<%= @t %>" />), registry: nil) }
          .to raise_error(Ruact::PreprocessorError, /title= holds ERB.*title=\{\.\.\.\}/m)
      end

      it "refuses empty braces, naming the attribute" do
        expect { described_class.transform(%(<PostCard title={} />), registry: nil) }
          .to raise_error(Ruact::PreprocessorError, /title=\{\} is empty/)
      end

      it "explains a > inside a quoted value" do
        expect { described_class.transform(%(<PostCard title="a > b" />), registry: nil) }
          .to raise_error(Ruact::PreprocessorError, /cannot contain `>`/)
      end

      it "refuses an attribute with = and no value" do
        expect { described_class.transform(%(<PostCard title= />), registry: nil) }
          .to raise_error(Ruact::PreprocessorError, /title= needs a value/)
      end
    end

    describe "self-closing tags" do
      it "transforms a self-closing tag with no props" do
        expect(transform.call("<Button />")).to eq(%(<%= __ruact_component__("Button", {}) %>))
      end

      it "transforms a self-closing tag with props" do
        result = transform.call("<LikeButton postId={@post.id} initialCount={5} />")
        expect(result).to eq(%(<%= __ruact_component__("LikeButton", { "postId" => @post.id, "initialCount" => 5 }) %>))
      end
    end

    describe "opening tags" do
      it "refuses an opening tag without children that does not close (Story 18-2)" do
        expect { transform.call("<Dialog open={true}>") }.to raise_error(Ruact::ComponentTagError, /never closed/)
      end
    end

    describe "passthrough (no transformation)" do
      it "does not touch lowercase HTML tags" do
        source = '<div class="foo"><span>hello</span></div>'
        expect(transform.call(source)).to eq(source)
      end

      it "does not touch ERB tags" do
        source = "<%= @post.title %>"
        expect(transform.call(source)).to eq(source)
      end
    end

    describe "complex prop expressions" do
      it "handles nested braces in a prop value" do
        result = transform.call("<Select options={Category.all.map { |c| c.id }} />")
        expect(result).to eq(%(<%= __ruact_component__("Select", { "options" => Category.all.map { |c| c.id } }) %>))
      end
    end

    describe "error handling" do
      it "raises PreprocessorError with line number and snippet for unclosed brace (AC#3)" do
        source = "<LikeButton postId={@post.id />"
        expect { transform.call(source) }
          .to raise_error(PreprocessorError, /unclosed brace/)
        expect { transform.call(source) }
          .to raise_error(PreprocessorError, /line 1/)
        expect { transform.call(source) }
          .to raise_error(PreprocessorError, /LikeButton/)
      end

      it "includes the correct line number for an error on line 3" do
        source = "line1\nline2\n<Bad prop={unclosed />"
        expect { transform.call(source) }
          .to raise_error(PreprocessorError, /line 3/)
      end
    end

    describe "multiple components" do
      it "transforms multiple components in the same string" do
        source = '<Button /> and <Badge label={"hello"} />'
        result = transform.call(source)
        expect(result).to match(/__ruact_component__\("Button"/)
        expect(result).to match(/__ruact_component__\("Badge"/)
        expect(result).to match(/"hello"/)
      end
    end

    describe "mixed content" do
      it "preserves surrounding HTML while transforming components" do
        source = <<~ERB
          <div class="container">
            <h1>Hello</h1>
            <LikeButton postId={1} />
          </div>
        ERB
        result = transform.call(source)
        expect(result).to match(/<div class="container">/)
        expect(result).to match(%r{<h1>Hello</h1>})
        expect(result).to match(/__ruact_component__\("LikeButton"/)
      end
    end

    # Bugfix (Sprint Change Proposal 2026-06-16 §4.5): `<Suspense delay="2.5">`
    # used to be ignored — the preprocessor never carried the attribute, so the
    # SuspenseElement always took its default delay. It now forwards an optional
    # `delay` as `data-ruact-delay` on the emitted <ruact-suspense> element.
    describe "Suspense delay attribute" do
      it "forwards delay to the ruact-suspense element as data-ruact-delay" do
        result = transform.call(%(<Suspense fallback="loading" delay="2.5"><Spinner /></Suspense>))
        expect(result).to include(%(data-ruact-delay="2.5"))
        expect(result).to include(%(data-ruact-fallback="loading"))
        expect(result).to include("</ruact-suspense>")
      end

      it "omits data-ruact-delay when no delay attribute is present" do
        result = transform.call(%(<Suspense fallback="loading"><Spinner /></Suspense>))
        expect(result).to include(%(data-ruact-fallback="loading"))
        expect(result).not_to include("data-ruact-delay")
      end

      it "extracts delay regardless of attribute order" do
        result = transform.call(%(<Suspense delay="0.75" fallback="wait"><X /></Suspense>))
        expect(result).to include(%(data-ruact-delay="0.75"))
        expect(result).to include(%(data-ruact-fallback="wait"))
      end

      it "accepts a single-quoted delay attribute" do
        result = transform.call(%(<Suspense fallback='loading' delay='1.5'><X /></Suspense>))
        expect(result).to include(%(data-ruact-delay="1.5"))
      end
    end

    # Story 18-2 — a component tag with a matching closing tag takes children:
    # its content stays ERB, inside the wrapper HtmlConverter turns into the
    # component's `children`. Every opening tag must close (`/>` or `</Name>`).
    describe "components with children", :story_18_2 do
      def run(source, identifier: nil)
        described_class.transform(source, identifier: identifier, registry: nil)
      end

      it "opens a wrapper for a paired tag and closes it at the closing tag" do
        expect(run(%(<Card title={@t}><p><%= @body %></p></Card>))).to eq(
          %(<%= __ruact_component_open__("Card", { "title" => @t }) %><p><%= @body %></p></ruact-component>)
        )
      end

      it "nests, the same component inside itself included" do
        expect(run(%(<Card><Card>x</Card><Button /></Card>))).to eq(
          %(<%= __ruact_component_open__("Card", {}) %><%= __ruact_component_open__("Card", {}) %>x</ruact-component>) +
          %(<%= __ruact_component__("Button", {}) %></ruact-component>)
        )
      end

      it "leaves ERB between the tags as ERB: loops, conditionals, partials" do
        source = %(<List>\n<% @items.each do |i| %><Item n={i} /><% end %>\n<%= render "row" if @x %>\n</List>)
        out = run(source)
        expect(out).to include(%(<% @items.each do |i| %><%= __ruact_component__("Item", { "n" => i }) %><% end %>))
        expect(out).to include(%(<%= render "row" if @x %>))
        expect(out).to end_with("</ruact-component>")
      end

      it "works around and inside Suspense" do
        out = run(%(<Card><Suspense fallback="…"><Card>late</Card></Suspense></Card>))
        expect(out).to eq(
          %(<%= __ruact_component_open__("Card", {}) %><ruact-suspense data-ruact-fallback="…">) +
          %(<%= __ruact_component_open__("Card", {}) %>late</ruact-component></ruact-suspense></ruact-component>)
        )
      end

      it "takes an empty pair" do
        expect(run("<Card></Card>")).to eq(%(<%= __ruact_component_open__("Card", {}) %></ruact-component>))
      end

      it "leaves tags inside ERB text alone" do
        source = %(<Card><%= "</Card>" %></Card>)
        expect(run(source)).to eq(%(<%= __ruact_component_open__("Card", {}) %><%= "</Card>" %></ruact-component>))
      end

      it "keeps a self-closing-only template byte-identical to before" do
        expect(run(%(<div><A x={1} /><B /></div>))).to eq(
          %(<div><%= __ruact_component__("A", { "x" => 1 }) %><%= __ruact_component__("B", {}) %></div>)
        )
      end

      describe "tags that do not pair" do
        it "refuses an opening tag that never closes, naming file:line and both fixes" do
          expect { run(%(<p>\n<Dialog open={true}>\n</p>), identifier: "app/views/x.html.erb") }
            .to raise_error(Ruact::ComponentTagError,
                            "ruact: <Dialog> at app/views/x.html.erb:2 is never closed — write " \
                            "`<Dialog ... />` for a component without children, or close it with `</Dialog>`.")
        end

        it "refuses it in a template that also has paired tags" do
          expect { run(%(<Card>\n<Dialog open={true}>\n</Card>)) }
            .to raise_error(Ruact::ComponentTagError, /<Dialog> at line 2 is never closed/)
        end

        it "refuses a closing tag that closes nothing" do
          expect { run(%(<div>\n</Card>\n</div>), identifier: "x.html.erb") }
            .to raise_error(Ruact::ComponentTagError,
                            "ruact: </Card> at x.html.erb:2 closes nothing — there is no open <Card> before it.")
        end

        it "names the tag left open when closing tags cross" do
          expect { run(%(<Card>\n<Box>\n</Card>\n</Box>)) }
            .to raise_error(Ruact::ComponentTagError, /<Box> at line 2 is never closed/)
        end

        it "refuses content between the tags together with a children prop" do
          expect { run(%(<Card children={@x}>y</Card>)) }
            .to raise_error(Ruact::ComponentTagError,
                            /<Card> at line 1 has content between its tags and a `children=\{\.\.\.\}` prop/)
        end

        it "reports the template's own line after a multi-line Suspense and multi-line ERB" do
          source = %(<Suspense\n  fallback="…">\n<% x = 1\n y = 2 %>\n</Suspense>\n<Card>)
          expect { run(source) }.to raise_error(Ruact::ComponentTagError, /<Card> at line 6 is never closed/)
        end

        it "takes `<X/>` (no space) as self-closing on the paired path too" do
          expect(run(%(<Suspense fallback="…"><LikeButton/></Suspense>))).to eq(
            %(<ruact-suspense data-ruact-fallback="…"><%= __ruact_component__("LikeButton", {}) %></ruact-suspense>)
          )
        end

        it "reads a tag inside ERB the same with or without a closing tag elsewhere in the file" do
          expect(run(%(<%# TODO: wrap in <Card> later %>\n<B />))).to eq(
            %(<%# TODO: wrap in <Card> later %>\n<%= __ruact_component__("B", {}) %>)
          )
          expect(run(%(<%= "<Foo>" %>))).to eq(%(<%= "<Foo>" %>))
        end

        it "takes a closing tag with whitespace before `>`" do
          expect(run(%(<Card>x</Card >))).to eq(%(<%= __ruact_component_open__("Card", {}) %>x</ruact-component>))
        end

        it "is a PreprocessorError" do
          expect(Ruact::ComponentTagError.ancestors).to include(Ruact::PreprocessorError)
        end

        it "stays linear on thousands of unpaired closing tags" do
          source = "<Card>#{'</Card>' * 5000}"
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect { run(source) }.to raise_error(Ruact::ComponentTagError, /closes nothing/)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
        end
      end
    end

    # Story 18-2 — a component name the manifest does not have fails while the
    # template compiles, with its file:line, when a manifest is available.
    describe "unknown component names", :story_18_2 do
      let(:manifest) do
        ClientManifest.from_hash(
          "LikeButton" => { "id" => "/LikeButton.jsx", "name" => "LikeButton", "chunks" => [] },
          "posts/_post_card" => { "id" => "/posts/_post_card.jsx", "name" => "default", "chunks" => [] }
        )
      end

      def run(source, identifier: "app/views/home/index.html.erb")
        described_class.transform(source, identifier: identifier, registry: manifest)
      end

      it "names the tag, the file:line and the closest component" do
        expect { run(%(<h1>Hi</h1>\n\n<LikeButon likes={1} />)) }
          .to raise_error(UnknownComponentError) do |e|
            expect(e.message).to start_with(
              %(ruact: <LikeButon> at app/views/home/index.html.erb:3 — Component "LikeButon" not found in manifest.)
            )
            expect(e.message).to include(%(Did you mean "LikeButton"?))
          end
      end

      it "checks paired tags too" do
        expect { run(%(<LikeButon>x</LikeButon>)) }.to raise_error(UnknownComponentError, /<LikeButon> at/)
      end

      it "accepts a co-located component from any folder, the controller not being known yet" do
        expect { run(%(<PostCard />), identifier: "app/views/shared/_list.html.erb") }.not_to raise_error
      end

      it "fails open without a manifest — the render path reports it, as before" do
        expect { described_class.transform(%(<Nope />), registry: nil) }.not_to raise_error
      end
    end

    # Story 13.5 (FR100) — preprocess-time component-contract validation, wired
    # through an injectable registry seam (a stub responding to +contract_for+).
    describe "component contract validation", :story_13_5 do
      # A minimal stub registry: maps component name → contract Hash (or nil).
      def registry_for(contracts)
        Class.new do
          def initialize(contracts) = (@contracts = contracts)
          def contract_for(name, **) = @contracts[name]
        end.new(contracts)
      end

      let(:contract) do
        { "props" => { "postId" => "required", "initialCount" => "optional" } }
      end
      let(:registry) { registry_for("LikeButton" => contract) }

      def run(source, identifier: "app/views/posts/show.html.erb")
        described_class.transform(source, identifier: identifier, registry: registry)
      end

      it "raises on a missing required prop, naming component + file:line + fix (AC#1, AC#3)" do
        expect { run("<LikeButton initialCount={5} />") }
          .to raise_error(ComponentContractError) do |e|
            expect(e.message).to include("LikeButton")
            expect(e.message).to include("app/views/posts/show.html.erb:1")
            expect(e.message).to include("postId")
            expect(e.message).to include("add the required prop")
          end
      end

      it "raises on an unknown prop with a did-you-mean suggestion (AC#3)" do
        expect { run("<LikeButton postId={1} postID={2} />") }
          .to raise_error(ComponentContractError, /did you mean "postId"\?/)
      end

      it "computes the correct line for a call site lower in the template" do
        source = "line1\nline2\n<LikeButton initialCount={5} />"
        expect { run(source) }.to raise_error(ComponentContractError, /show\.html\.erb:3/)
      end

      it "passes a valid call and emits the normal placeholder (AC#1)" do
        result = run("<LikeButton postId={@post.id} initialCount={5} />")
        expect(result)
          .to eq(%(<%= __ruact_component__("LikeButton", { "postId" => @post.id, "initialCount" => 5 }) %>))
      end

      it "does NOT re-wrap the contract error with the generic line/snippet tail" do
        expect { run("<LikeButton initialCount={5} />") }
          .to raise_error(ComponentContractError) { |e| expect(e.message).not_to match(/at line \d+:/) }
      end

      # AC#2 — opt-in / byte-identity: a component with no contract entry is
      # validated NOT AT ALL and emits the exact same placeholder as pre-13.5.
      describe "opt-in fail-open (AC#2)" do
        it "emits byte-identical output for a contract-less component" do
          source = "<NavBar foo={1} bar={2} />"
          with_contract    = run(source) # registry has NO "NavBar" entry → fail open
          without_registry = described_class.transform(source, registry: nil)
          expected = %(<%= __ruact_component__("NavBar", { "foo" => 1, "bar" => 2 }) %>)
          expect(with_contract).to eq(expected)
          expect(without_registry).to eq(expected)
        end

        it "never consults the registry for a no-tag source (fast path)" do
          spy_registry = registry_for({})
          allow(spy_registry).to receive(:contract_for).and_call_original
          result = described_class.transform("<div><p>plain</p></div>", registry: spy_registry)
          expect(result).to eq("<div><p>plain</p></div>")
          expect(spy_registry).not_to have_received(:contract_for)
        end

        # Codex review (Patch 2) — the DEFAULT registry (`Ruact.manifest`) must
        # not even be read when the source has no component tags.
        it "never reads Ruact.manifest for a no-tag source (default registry)" do
          allow(Ruact).to receive(:manifest)
          described_class.transform("<div><p>plain</p></div>")
          expect(Ruact).not_to have_received(:manifest)
        end
      end

      describe "slots (AC#5)" do
        let(:contract) do
          { "props" => { "title" => "required" }, "slots" => { "header" => "required" } }
        end
        let(:registry) { registry_for("Card" => contract) }

        it "raises when a required slot attribute is omitted at the call site" do
          expect { run("<Card title={@t} />") }
            .to raise_error(ComponentContractError, /missing required slot.*header/m)
        end

        it "passes when the declared slot is supplied as an attribute" do
          expect { run("<Card title={@t} header={@h} />") }.not_to raise_error
        end
      end

      # Story 18-2 — content between the tags is the `children` prop.
      describe "children", :story_18_2 do
        let(:registry) do
          registry_for(
            "Card" => { "props" => { "title" => "required" } },
            "Panel" => { "props" => { "title" => "required" }, "slots" => { "children" => "required" } }
          )
        end

        it "counts content between the tags as children, unknown to a contract that does not declare it" do
          expect { run("<Card title={@t}>x</Card>") }.to raise_error(ComponentContractError, /children/)
        end

        it "counts no children for an empty or blank pair, like a self-closing tag" do
          expect { run("<Card title={@t}></Card>") }.not_to raise_error
          expect { run("<Panel title={@t}>\n  \n</Panel>") }
            .to raise_error(ComponentContractError, /missing required slot.*children/m)
        end

        it "satisfies a contract that declares children" do
          expect { run("<Panel title={@t}>x</Panel>") }.not_to raise_error
        end

        it "reports a required children slot left empty by a self-closing tag" do
          expect do
            run("<Panel title={@t} />")
          end.to raise_error(ComponentContractError, /missing required slot.*children/m)
        end
      end
    end
  end
end
