# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe ErbPreprocessorHook do
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
    # Story 13.5 — the hook now forwards +template.identifier+ into the
    # preprocessor (for contract-violation file:line), so the stand-in template
    # must answer +identifier+.
    let(:fake_template) { Struct.new(:identifier).new("app/views/posts/show.html.erb") }

    describe "#call" do
      it "applies ErbPreprocessor.transform to source before calling super" do
        source = "<LikeButton postId={1} />"
        result = handler.call(fake_template, source)
        expect(result).to include("__ruact_component__")
        expect(result).to include('"LikeButton"')
        expect(result).not_to include("<LikeButton")
      end

      it "passes source unchanged when no PascalCase tags present (fast-path)" do
        source = "<div class=\"hello\"><p>No ruact here</p></div>"
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
        expect(result).to include("__ruact_component__")
      end
    end
  end
end
