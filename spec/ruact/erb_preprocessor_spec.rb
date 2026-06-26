# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ErbPreprocessor do
    subject(:transform) { ->(source) { described_class.transform(source) } }

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
      it "transforms an opening tag with props" do
        result = transform.call("<Dialog open={true}>")
        expect(result).to eq(%(<%= __ruact_component__("Dialog", { "open" => true }) %>))
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
    end
  end
end
