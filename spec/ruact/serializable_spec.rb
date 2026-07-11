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

        ruact_props :id, :title
      end
    end

    describe "ruact_props (AC#2)" do
      it "raises ArgumentError for undefined method at class load time" do
        expect do
          Class.new do
            include Ruact::Serializable

            ruact_props :nonexistent
          end
        end.to raise_error(ArgumentError, /nonexistent/)
      end
    end

    # Regression doc for the AGENTS.md serialization-contract fix (2026-07):
    # proves WHY the emitted AGENTS.md must NOT put `ruact_props` on an
    # ActiveRecord model. AR defines attribute reader methods LAZILY, so the
    # eager `method_defined?` check in `ruact_props` fires BEFORE `#title`
    # exists and raises at class-load — an agent copying that pattern ships an
    # app that crashes on boot. The shipped scaffold + AGENTS.md serialize AR
    # rows with a manual wire hash (`{ id: post.id, title: post.title }`);
    # `ruact_props` is reserved for POROs whose readers already exist. The AR
    # connection/schema are built INSIDE the example so the suite carries no
    # DB dependency at boot.
    describe "ActiveRecord attribute laziness (AGENTS.md contract)" do
      it "rejects a real column reader AR has not yet defined at class-load" do
        require "active_record"
        already_connected =
          ActiveRecord::Base.respond_to?(:connected?) && ActiveRecord::Base.connected?
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:") unless already_connected
        # Direct connection DDL (NOT `Schema.define`) so we touch nothing global:
        # no `schema_migrations` / `ar_internal_metadata`, no `Schema.verbose`.
        ActiveRecord::Base.connection.create_table(:ruact_props_probe_posts, force: true) do |t|
          t.string :title
        end

        # `title` IS a column, yet the reader is not defined at class-load…
        expect do
          Class.new(ActiveRecord::Base) do
            self.table_name = "ruact_props_probe_posts"
            include Ruact::Serializable

            ruact_props :title
          end
        end.to raise_error(ArgumentError, /title.*not defined/)
      ensure
        # Zero global footprint on either path: drop only the probe table we
        # created, and only tear down a connection we ourselves opened.
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
          ActiveRecord::Base.connection.drop_table(:ruact_props_probe_posts, if_exists: true)
        end
        ActiveRecord::Base.remove_connection unless already_connected
      end
    end

    describe "ruact_serialize (AC#1)" do
      it "returns only declared props" do
        obj = serializable_class.new
        expect(obj.ruact_serialize).to eq({ "id" => 1, "title" => "Hello" })
      end

      it "excludes undeclared attributes" do
        obj = serializable_class.new
        expect(obj.ruact_serialize.keys).not_to include("secret")
      end
    end

    describe "ruact_props_list" do
      it "returns the declared prop names as symbols" do
        expect(serializable_class.ruact_props_list).to eq(%i[id title])
      end
    end
  end
end
