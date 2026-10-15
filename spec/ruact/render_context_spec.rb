# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe RenderContext do
    subject(:ctx) { described_class.new }

    describe "#register" do
      it "appends a new component entry" do
        ctx.register("NavBar", { "currentUser" => 1 })
        expect(ctx.components.length).to eq(1)
        expect(ctx.components.first[:name]).to eq("NavBar")
        expect(ctx.components.first[:props]).to eq({ "currentUser" => 1 })
      end

      it "returns a token of the form __RUACT_<render>_<index>__" do
        token = ctx.register("Foo", {})
        expect(token).to match(/\A__RUACT_\h{8}_0__\z/)
      end

      it "increments token indices across successive registrations, under one render id" do
        tokens = %w[A B C].map { |name| ctx.register(name, {}) }
        render_ids = tokens.map { |token| token[/__RUACT_(\h+)_/, 1] }.uniq
        expect(render_ids.length).to eq(1)
        expect(tokens).to eq(%w[0 1 2].map { |n| "__RUACT_#{render_ids.first}_#{n}__" })
      end

      # Story 19-2 (AC9) — a marker a `cache` block stored in another render is
      # never one of this render's.
      it "gives each render its own tokens" do
        expect(described_class.new.register("A", {})).not_to eq(described_class.new.register("A", {}))
      end
    end

    describe "#components" do
      it "starts empty" do
        expect(ctx.components).to eq([])
      end
    end

    describe "#resolve" do
      let(:manifest) do
        instance_double(Ruact::ClientManifest).tap do |m|
          allow(m).to receive(:reference_for) { |name, **| "ref:#{name}" }
        end
      end

      it "gives each registered component its client reference, in registration order" do
        ctx.register("NavBar", { "x" => 1 })
        ctx.register("Footer", {})
        tokens = ctx.components.map { |entry| entry[:token] }
        expect(ctx.resolve(manifest, controller_path: "posts")).to eq(
          [{ token: tokens[0], name: "NavBar", ref: "ref:NavBar", props: { "x" => 1 } },
           { token: tokens[1], name: "Footer", ref: "ref:Footer", props: {} }]
        )
        expect(manifest).to have_received(:reference_for).with("NavBar", controller_path: "posts")
      end
    end

    describe "#resolve from:" do
      let(:manifest) do
        instance_double(Ruact::ClientManifest).tap do |m|
          allow(m).to receive(:reference_for) { |name, **| "ref:#{name}" }
        end
      end

      it "resolves only the components registered after the first +from+ (Story 19-1)" do
        ctx.register("NavBar", {})
        ctx.register("Footer", {})
        expect(ctx.resolve(manifest, from: 1).map { |entry| entry[:name] }).to eq(["Footer"])
      end
    end

    describe "deferred blocks (Story 19-1)" do
      it "does not defer unless the render streams" do
        expect(ctx.deferring?).to be(false)
        expect(described_class.new(deferring: true).deferring?).to be(true)
      end

      it "keeps each block under the key it returns, and knows no other render's", :aggregate_failures do
        first = RenderContext::Block.new(:view, -> {}, "posts/show", :template, nil)
        second = RenderContext::Block.new(:view, -> {}, "posts/_card", :partial, nil)
        first_key = ctx.defer_block(first)
        second_key = ctx.defer_block(second)
        expect(ctx.block(second_key)).to be(second)
        expect(ctx.block(first_key)).to be(first)
        expect(ctx.block(first_key.sub(/-0\z/, "-2"))).to be_nil
        # Story 19-2 (AC9) — another render's key, as a cached fragment holds it.
        other = described_class.new(deferring: true)
        expect(ctx.block(other.defer_block(first))).to be_nil
      end

      it "notes the unstreamed-Suspense message once per render" do
        expect(ctx.unstreamed_suspense_noted?).to be(false)
        ctx.note_unstreamed_suspense!
        expect(ctx.unstreamed_suspense_noted?).to be(true)
      end
    end

    describe "isolation" do
      it "two contexts are independent" do
        a = described_class.new
        b = described_class.new
        a.register("A", {})
        expect(b.components).to be_empty
        expect(a.components.length).to eq(1)
      end
    end
  end
end
