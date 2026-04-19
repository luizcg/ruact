# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ErbPreprocessor do
    subject(:transform) { ->(source) { described_class.transform(source) } }

    describe "self-closing tags" do
      it "transforms a self-closing tag with no props" do
        expect(transform.call("<Button />")).to eq(%(<%= __rsc_component__("Button", {}) %>))
      end

      it "transforms a self-closing tag with props" do
        result = transform.call("<LikeButton postId={@post.id} initialCount={5} />")
        expect(result).to eq(%(<%= __rsc_component__("LikeButton", { "postId" => @post.id, "initialCount" => 5 }) %>))
      end
    end

    describe "opening tags" do
      it "transforms an opening tag with props" do
        result = transform.call("<Dialog open={true}>")
        expect(result).to eq(%(<%= __rsc_component__("Dialog", { "open" => true }) %>))
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
        expect(result).to eq(%(<%= __rsc_component__("Select", { "options" => Category.all.map { |c| c.id } }) %>))
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
        expect(result).to match(/__rsc_component__\("Button"/)
        expect(result).to match(/__rsc_component__\("Badge"/)
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
        expect(result).to match(/__rsc_component__\("LikeButton"/)
      end
    end
  end
end
