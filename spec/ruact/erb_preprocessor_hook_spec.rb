# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ErbPreprocessorHook do
    # Minimal stand-in for ActionView::Template::Handlers::ERB:
    # base implementation just returns source unchanged so we can inspect the
    # transformed version that the hook passes to super.
    let(:handler_class) do
      klass = Class.new do
        def call(_template, source)
          source
        end
      end
      klass.prepend(described_class)
      klass
    end

    let(:handler) { handler_class.new }
    let(:fake_template) { Object.new }

    describe "#call" do
      it "applies ErbPreprocessor.transform to source before calling super" do
        source = "<LikeButton postId={1} />"
        result = handler.call(fake_template, source)
        expect(result).to include("__rsc_component__")
        expect(result).to include('"LikeButton"')
        expect(result).not_to include("<LikeButton")
      end

      it "passes source unchanged when no PascalCase tags present (fast-path)" do
        source = "<div class=\"hello\"><p>No RSC here</p></div>"
        result = handler.call(fake_template, source)
        expect(result).to eq(source)
      end

      it "processes multiple components in a single template" do
        source = "<NavBar /><LikeButton postId={1} />"
        result = handler.call(fake_template, source)
        expect(result).to include('"NavBar"')
        expect(result).to include('"LikeButton"')
      end

      it "transforms Suspense tags correctly" do
        source = "<Suspense fallback=\"Loading\"><PostCard /></Suspense>"
        result = handler.call(fake_template, source)
        expect(result).to include("__rsc_component__")
      end
    end
  end
end
