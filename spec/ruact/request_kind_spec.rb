# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ruact::RequestKind do
  def request(headers)
    ActionDispatch::Request.new(headers.transform_keys { |name| "HTTP_#{name.upcase.tr('-', '_')}" })
  end

  describe ".flight?" do
    it "is true for either header, and false for a browser asking for HTML" do
      expect(described_class.flight?(request("Accept" => "text/x-component"))).to be(true)
      expect(described_class.flight?(request("Ruact-Request" => "1"))).to be(true)
      expect(described_class.flight?(request("Accept" => "text/html"))).to be(false)
    end
  end

  describe ".from_router?" do
    it "is true only for the router's own header: any Flight client is not the router" do
      expect(described_class.from_router?("HTTP_RUACT_REQUEST" => "1")).to be(true)
      expect(described_class.from_router?("HTTP_ACCEPT" => "text/x-component")).to be(false)
    end
  end

  describe ".flight_signal" do
    it "names the header that made the request a Flight one" do
      expect(described_class.flight_signal(request("Accept" => "text/x-component", "Ruact-Request" => "1")))
        .to eq("Accept: text/x-component")
      expect(described_class.flight_signal(request("Ruact-Request" => "1"))).to eq("Ruact-Request: 1")
    end
  end
end
