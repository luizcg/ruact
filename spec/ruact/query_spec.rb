# frozen_string_literal: true

# Story 9.4 — unit spec for the Ruact::Query base class. Deliberately NO Rails
# boot (AC3): a query subclass is exercised with a plain double standing in for
# the dispatch context, proving `CatalogQuery.new(fake_context).categories` is
# unit-testable in isolation.
require "spec_helper"

module Ruact
  RSpec.describe Query, :story_9_4 do
    let(:fake_user) { { "id" => 42 } }
    let(:fake_params) { { "q" => "ruby" } }
    let(:fake_request) { instance_double(Object) }
    let(:fake_session) { { "token" => "abc" } }
    let(:context) do
      double(
        current_user: fake_user,
        params: fake_params,
        request: fake_request,
        session: fake_session
      )
    end

    let(:query_class) do
      Class.new(described_class) do
        def categories
          %w[books games]
        end

        def whoami
          current_user
        end

        def search
          params["q"]
        end
      end
    end

    describe "Story 9.4 — context accessors delegate to the injected context (AC3)" do
      subject(:query) { query_class.new(context) }

      it "exposes current_user from the context" do
        expect(query.whoami).to eq(fake_user)
      end

      it "exposes params from the context" do
        expect(query.search).to eq("ruby")
      end

      it "exposes request from the context" do
        expect(query.request).to be(fake_request)
      end

      it "exposes session from the context" do
        expect(query.session).to eq(fake_session)
      end

      it "is unit-testable with a plain fake context and no Rails boot (AC3)" do
        expect(query_class.new(context).categories).to eq(%w[books games])
      end
    end

    describe "Story 9.4 — accessor methods are inherited, never own methods of the subclass (AC1)" do
      it "keeps current_user/params/request/session OUT of the subclass's public_instance_methods(false)" do
        own = query_class.public_instance_methods(false)
        expect(own).to contain_exactly(:categories, :whoami, :search)
      end

      it "defines the accessors on Ruact::Query itself (inherited by every subclass)" do
        expect(described_class.public_instance_methods(false))
          .to include(:current_user, :params, :request, :session)
      end
    end

    describe "Story 9.4 — ruact_skip_before_action class macro (AC4 / D1)" do
      it "records the callback with its options on the query class" do
        klass = Class.new(described_class)
        klass.ruact_skip_before_action(:require_login, only: :categories)
        expect(klass.__ruact_skipped_callbacks).to eq([[[:require_login], { only: :categories }]])
      end

      it "accepts multiple callbacks in one call, mirroring Rails' skip_before_action" do
        klass = Class.new(described_class)
        klass.ruact_skip_before_action(:require_login, :check_tenant)
        expect(klass.__ruact_skipped_callbacks).to eq([[%i[require_login check_tenant], {}]])
      end

      it "accumulates across calls in declaration order" do
        klass = Class.new(described_class)
        klass.ruact_skip_before_action(:require_login)
        klass.ruact_skip_before_action(:check_tenant, raise: false)
        expect(klass.__ruact_skipped_callbacks)
          .to eq([[[:require_login], {}], [[:check_tenant], { raise: false }]])
      end

      it "keeps the recorded skips per-class — sibling query classes never share them" do
        klass_a = Class.new(described_class)
        klass_b = Class.new(described_class)
        klass_a.ruact_skip_before_action(:require_login)
        expect(klass_b.__ruact_skipped_callbacks).to be_empty
      end
    end
  end
end
