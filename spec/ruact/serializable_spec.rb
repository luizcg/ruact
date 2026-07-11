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

    # Story 13.7 — `ruact_props` on ActiveRecord models.
    #
    # ActiveRecord defines its attribute reader methods LAZILY (on first
    # instance access), so at the moment the `ruact_props :title` macro runs,
    # `method_defined?(:title)` is `false` even for a real column. The eager
    # boot check used to raise there, so an AR model that included
    # `Ruact::Serializable` crashed at class-load. Story 13.7 makes the check
    # HYBRID: POROs are still checked eagerly at class-load (byte-identical, see
    # the block above), while for a lazy-attribute (AR) class the loud check is
    # DEFERRED to the first `ruact_serialize` — where the DB is up and the reader
    # exists. Loudness is preserved: a bogus prop still raises a clean
    # `ArgumentError`, just at first render of that model instead of at boot.
    #
    # Zero suite-boot DB footprint: the connection + table are built INSIDE the
    # example (direct connection DDL, NOT `Schema.define`, so we touch nothing
    # global — no `schema_migrations` / `ar_internal_metadata`), and only a
    # connection we ourselves opened is torn down.
    describe "ActiveRecord models (Story 13.7)", :story_13_7 do
      before do
        require "active_record"
        @already_connected =
          ActiveRecord::Base.respond_to?(:connected?) && ActiveRecord::Base.connected?
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:") unless @already_connected
        ActiveRecord::Base.connection.create_table(:ruact_props_probe_posts, force: true) do |t|
          t.string :title
          t.string :secret
        end
      end

      after do
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
          ActiveRecord::Base.connection.drop_table(:ruact_props_probe_posts, if_exists: true)
        end
        ActiveRecord::Base.remove_connection unless @already_connected
      end

      let(:ar_model) do
        Class.new(ActiveRecord::Base) do
          self.table_name = "ruact_props_probe_posts"
          include Ruact::Serializable

          ruact_props :id, :title
        end
      end

      it "loads without raising even though readers are lazy at class-load (AC#1)" do
        expect { ar_model }.not_to raise_error
      end

      it "ruact_serialize returns only the declared allowlist (AC#1)" do
        row = ar_model.create!(title: "Hello", secret: "top-secret")

        expect(row.ruact_serialize).to eq({ "id" => row.id, "title" => "Hello" })
        expect(row.ruact_serialize.keys).not_to include("secret")
      end

      it "defers the loud check to first serialize for a bogus prop (AC#2)" do
        model = nil

        # Declaring a bogus prop on an AR model does NOT raise at class-load —
        # the reader might still be defined lazily, so the check is deferred.
        expect do
          model = Class.new(ActiveRecord::Base) do
            self.table_name = "ruact_props_probe_posts"
            include Ruact::Serializable

            ruact_props :ttile # typo — neither a column nor a method
          end
        end.not_to raise_error

        # …but it fails LOUDLY (same clean ArgumentError) on first serialize.
        expect { model.new.ruact_serialize }
          .to raise_error(ArgumentError, /ttile.*not defined/)
      end

      it "re-validates loudly when props are re-declared after a first serialize (AC#2)" do
        model = Class.new(ActiveRecord::Base) do
          self.table_name = "ruact_props_probe_posts"
          include Ruact::Serializable

          ruact_props :id, :title
        end

        # First serialize succeeds and memoizes "validated"…
        model.create!(title: "Hello").ruact_serialize

        # …a re-declaration with a bogus prop must NOT be masked by the stale
        # memo: the next serialize still raises the clean ArgumentError.
        model.ruact_props :id, :ttile
        expect { model.new.ruact_serialize }
          .to raise_error(ArgumentError, /ttile.*not defined/)
      end

      it "re-validates an inherited declaration re-declared on the parent after a subclass serialize (AC#2)" do
        parent = Class.new(ActiveRecord::Base) do
          self.table_name = "ruact_props_probe_posts"
          include Ruact::Serializable

          ruact_props :id, :title
        end
        child = Class.new(parent)

        # The subclass serializes first, memoizing the inherited (valid) list…
        parent.create!(title: "Hello")
        child.first.ruact_serialize

        # …then the PARENT re-declares with a bogus prop. The subclass must not
        # keep serving its stale memo: its next serialize re-validates loudly.
        parent.ruact_props :id, :ttile
        expect { child.first.ruact_serialize }
          .to raise_error(ArgumentError, /ttile.*not defined/)
      end

      it "dispatches through serialize_serializable under strict true AND false (AC#4)" do
        row = ar_model.create!(title: "Hello", secret: "top-secret")

        [true, false].each do |strict|
          output = Ruact::Flight::Renderer.render(
            row, Ruact::ClientManifest.from_hash({}), strict_serialization: strict
          )
          expect(output).to include("Hello")
          expect(output).not_to include("top-secret")
        end
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
