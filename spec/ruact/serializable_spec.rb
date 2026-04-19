# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe Serializable do
    let(:serializable_class) do
      Class.new do
        include Ruact::Serializable

        attr_reader :id, :title, :secret

        def initialize
          @id     = 1
          @title  = "Hello"
          @secret = "top-secret"
        end

        rsc_props :id, :title
      end
    end

    describe "rsc_props (AC#2)" do
      it "raises ArgumentError for undefined method at class load time" do
        expect do
          Class.new do
            include Ruact::Serializable

            rsc_props :nonexistent
          end
        end.to raise_error(ArgumentError, /nonexistent/)
      end
    end

    describe "rsc_serialize (AC#1)" do
      it "returns only declared props" do
        obj = serializable_class.new
        expect(obj.rsc_serialize).to eq({ "id" => 1, "title" => "Hello" })
      end

      it "excludes undeclared attributes" do
        obj = serializable_class.new
        expect(obj.rsc_serialize.keys).not_to include("secret")
      end
    end

    describe "rsc_props_list" do
      it "returns the declared prop names as symbols" do
        expect(serializable_class.rsc_props_list).to eq(%i[id title])
      end
    end
  end
end
