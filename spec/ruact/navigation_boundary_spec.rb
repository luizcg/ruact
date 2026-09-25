# frozen_string_literal: true

require "action_dispatch"
require "spec_helper"
require "rack/mock"
require "ruact/navigation_boundary"

# Story 17.0f — the parts of the boundary that need no booted app. The routing
# cases themselves (constraints, engines, redirects, verbs) are proven against a
# real route table in navigation_boundary_boot_spec.rb.
RSpec.describe Ruact::NavigationBoundary, :story_17_0f do
  let(:router_env) { Rack::MockRequest.env_for("/people/1", "HTTP_RUACT_REQUEST" => "1") }

  describe Ruact::NavigationBoundary::Middleware do
    let(:app) { instance_double(Proc, call: [200, {}, ["app"]]) }
    let(:classifier) { instance_double(Ruact::NavigationBoundary::Classifier) }
    let(:middleware) { described_class.new(app, classifier: classifier) }

    it "answers native WITHOUT calling the app", :aggregate_failures do
      allow(classifier).to receive(:classify).and_return(:native)

      status, headers, body = middleware.call(router_env)

      expect([status, headers["ruact-boundary"], body]).to eq([200, "native", []])
      expect(headers["vary"]).to eq("Ruact-Request")
      expect(headers["cache-control"]).to eq("no-store")
      expect(app).not_to have_received(:call)
    end

    it "lets :ruact and :pass through to the app" do
      %i[ruact pass].each do |verdict|
        allow(classifier).to receive(:classify).and_return(verdict)
        expect(middleware.call(router_env).last).to eq(["app"])
      end
    end

    # Only the ruact router sends Ruact-Request: a browser navigation, a server
    # function (Accept: application/json) or anything else is not classified at all.
    it "never classifies a request the router did not send" do
      allow(classifier).to receive(:classify)

      middleware.call(Rack::MockRequest.env_for("/people/1", "HTTP_ACCEPT" => "application/json"))

      expect(classifier).not_to have_received(:classify)
    end
  end

  describe Ruact::NavigationBoundary::Classifier do
    # A wrong :native would skip ruact on a ruact page; a wrong :ruact would bring
    # the dead click back. Anything the classifier cannot answer lets the
    # request through, which is exactly what happened before it existed.
    it "lets the request through when the router raises" do
      router = Object.new
      def router.recognize(_request) = raise(ArgumentError, "unexpected route shape")

      expect(described_class.new(router).classify(router_env)).to eq(:pass)
    end

    it "lets the request through when nothing matches" do
      router = Object.new
      def router.recognize(_request) = nil

      expect(described_class.new(router).classify(router_env)).to eq(:pass)
    end
  end
end
