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

      it "returns a token of the form __RUACT_<index>__" do
        token = ctx.register("Foo", {})
        expect(token).to eq("__RUACT_0__")
      end

      it "increments token indices across successive registrations" do
        t0 = ctx.register("A", {})
        t1 = ctx.register("B", {})
        t2 = ctx.register("C", {})
        expect([t0, t1, t2]).to eq(%w[__RUACT_0__ __RUACT_1__ __RUACT_2__])
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
        expect(ctx.resolve(manifest, controller_path: "posts")).to eq(
          [{ token: "__RUACT_0__", name: "NavBar", ref: "ref:NavBar", props: { "x" => 1 } },
           { token: "__RUACT_1__", name: "Footer", ref: "ref:Footer", props: {} }]
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

      it "keeps each block under the index it returns", :aggregate_failures do
        first = RenderContext::Block.new(:view, -> {}, "posts/show", :template, nil)
        second = RenderContext::Block.new(:view, -> {}, "posts/_card", :partial, nil)
        expect(ctx.defer_block(first)).to eq(0)
        expect(ctx.defer_block(second)).to eq(1)
        expect(ctx.block(1)).to be(second)
        expect { ctx.block(2) }.to raise_error(IndexError)
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
