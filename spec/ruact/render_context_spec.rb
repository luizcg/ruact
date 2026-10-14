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
