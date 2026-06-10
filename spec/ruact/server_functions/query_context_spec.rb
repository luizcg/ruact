# frozen_string_literal: true

# Story 9.4 — unit spec for the per-request query context (D3). The context
# wraps the DISPATCHING controller instance and delegates to it: because the
# internal dispatch controller inherits `Ruact.config.query_parent_controller`,
# `controller.current_user` IS the host's own method (Devise / Pundit /
# hand-rolled). No Rails boot needed here — a plain stub controller suffices.
require "spec_helper"

module Ruact
  module ServerFunctions
    RSpec.describe QueryContext, :story_9_4 do
      describe "Story 9.4 — delegation to the dispatching controller (AC3 / D3)" do
        let(:controller_class) do
          Class.new do
            def params  = { "q" => "x" }
            def request = :the_request
            def session = { "sid" => 1 }

            def current_user
              { "id" => 7 }
            end
          end
        end

        subject(:context) { described_class.new(controller: controller_class.new) }

        it "delegates params" do
          expect(context.params).to eq("q" => "x")
        end

        it "delegates request" do
          expect(context.request).to eq(:the_request)
        end

        it "delegates session" do
          expect(context.session).to eq("sid" => 1)
        end

        it "delegates current_user to the host's own method" do
          expect(context.current_user).to eq("id" => 7)
        end
      end

      describe "Story 9.4 — current_user reaches a PRIVATE host helper too" do
        let(:controller_class) do
          Class.new do
            private

            def current_user
              :private_user
            end
          end
        end

        it "resolves it (hand-rolled apps commonly define current_user private)" do
          context = described_class.new(controller: controller_class.new)
          expect(context.current_user).to eq(:private_user)
        end
      end

      describe "Story 9.4 — clear error when the host defines no current_user (D3)" do
        it "raises NoMethodError naming the parent controller and the fix" do
          context = described_class.new(controller: Class.new.new)
          expect { context.current_user }.to raise_error(NoMethodError, /current_user/) do |error|
            expect(error.message).to include("query_parent_controller")
          end
        end
      end
    end
  end
end
