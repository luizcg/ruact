# frozen_string_literal: true

# Story 8.3 — covers `Ruact::ServerAction` extended onto a Module: AC1
# (registration shape + no method defined on host module) and AC6 (guard-
# rail matrix mirroring the controller-DSL path adapted to module context).

require "spec_helper"

RSpec.describe Ruact::ServerAction, :story_8_3 do
  describe "AC1 — extend Ruact::ServerAction + ruact_action registers a standalone host" do
    it "registers a standalone host in Ruact.action_registry with controller: <the Module>" do
      mod = Module.new do
        extend Ruact::ServerAction

        def self.name
          "AC1RegistrationModule"
        end

        ruact_action(:standalone_create_post) { |_params| { ok: true } }
      end

      entries = Ruact.action_registry.entries
      expect(entries).to include(:standalone_create_post)

      entry = entries[:standalone_create_post]
      expect(entry).to be_a(Ruact::ServerFunctions::RegistryEntry)
      expect(entry.kind).to eq(:action)
      expect(entry.controller).to be(mod)
      expect(entry.controller).to be_a(Module)
      expect(entry.controller).not_to be_a(Class)
      expect(entry.js_identifier).to eq("standaloneCreatePost")
      expect(entry.block).to be_a(Proc)
    end

    it "does NOT define an instance method on the host module — the block is reachable " \
       "only through the gem endpoint, never as a Ruby method" do
      mod = Module.new do
        extend Ruact::ServerAction

        def self.name
          "AC1NoMethodModule"
        end

        ruact_action(:no_method_exposed) { |_params| nil }
      end

      expect(mod.respond_to?(:no_method_exposed)).to be(false)
      expect(mod.instance_methods).not_to include(:no_method_exposed)
      expect(mod.singleton_methods).not_to include(:no_method_exposed)
      # Direct dispatch attempts (someone trying to `Mod.send(:no_method_exposed)`
      # should fail with NoMethodError) — proves the surface is endpoint-only.
      expect { mod.send(:no_method_exposed, {}) }.to raise_error(NoMethodError)
    end
  end

  describe "AC6 — guard-rail matrix (mirror controller-DSL adapted to module context)" do
    let(:host) do
      Module.new do
        extend Ruact::ServerAction

        def self.name
          "GuardRailModule"
        end
      end
    end

    it "raises ArgumentError when given a String instead of a Symbol" do
      expect do
        host.module_eval { ruact_action("create_post") { |_p| nil } }
      end.to raise_error(ArgumentError, /ruact_action requires a Symbol/)
    end

    it "raises ArgumentError when the block is missing" do
      expect { host.module_eval { ruact_action(:create_post) } }
        .to raise_error(ArgumentError, /requires a block/)
    end

    it "raises ArgumentError when the block accepts no positional argument" do
      expect do
        host.module_eval { ruact_action(:create_post) {} } # no positional arg
      end.to raise_error(ArgumentError, /exactly one positional parameter/)
    end

    it "raises ArgumentError when the block accepts more than one positional argument" do
      expect do
        host.module_eval { ruact_action(:create_post) { |_a, _b| nil } }
      end.to raise_error(ArgumentError, /exactly one positional parameter/)
    end

    it "raises ArgumentError when the block has a required keyword argument" do
      block_with_kwarg = ->(_p, required:) { required }
      expect do
        host.module_eval { ruact_action(:create_post, &block_with_kwarg) }
      end.to raise_error(ArgumentError, /no required keyword arguments/)
    end

    it "ACCEPTS a block with a single positional arg" do
      expect do
        host.module_eval { ruact_action(:create_post) { |_p| nil } }
      end.not_to raise_error
    end

    it "ACCEPTS a block with a splat positional arg" do
      another_host = Module.new do
        extend Ruact::ServerAction

        def self.name
          "SplatHost"
        end
      end
      expect do
        another_host.module_eval { ruact_action(:create_post) { |*_args| nil } }
      end.not_to raise_error
    end

    it "ACCEPTS a block with optional keyword args" do
      another_host = Module.new do
        extend Ruact::ServerAction

        def self.name
          "OptKwHost"
        end
      end
      expect do
        another_host.module_eval { ruact_action(:create_post) { |_p, key: nil| key } }
      end.not_to raise_error
    end

    it "raises Ruact::ConfigurationError for a bad naming-bridge symbol (:Create_Post)" do
      expect do
        host.module_eval { ruact_action(:Create_Post) { |_p| nil } }
      end.to raise_error(Ruact::ConfigurationError) do |error|
        expect(error.message).to include(":Create_Post")
        expect(error.message).to include("GuardRailModule")
      end
    end

    it "raises Ruact::ConfigurationError for a JS-reserved-word target (:class → \"class\")" do
      expect do
        host.module_eval { ruact_action(:class) { |_p| nil } }
      end.to raise_error(Ruact::ConfigurationError, /JS reserved word/)
    end

    it "raises Ruact::ConfigurationError for a ruact-runtime-reserved target (:revalidate)" do
      expect do
        host.module_eval { ruact_action(:revalidate) { |_p| nil } }
      end.to raise_error(Ruact::ConfigurationError) do |error|
        expect(error.message).to include("revalidate")
      end
    end

    it "raises Ruact::ConfigurationError for the second standalone host declaring the same symbol" do
      host.module_eval { ruact_action(:dup_symbol) { |_p| nil } }
      second_host = Module.new do
        extend Ruact::ServerAction

        def self.name
          "SecondHostModule"
        end
      end
      expect do
        second_host.module_eval { ruact_action(:dup_symbol) { |_p| nil } }
      end.to raise_error(Ruact::ConfigurationError) do |error|
        expect(error.message).to include(":dup_symbol")
        expect(error.message).to include("GuardRailModule")
        expect(error.message).to include("SecondHostModule")
      end
    end

    it "does NOT have a FRAMEWORK_RESERVED_METHODS check — standalone modules can use " \
       "names that would clobber an ActionController method (e.g., :params), since the " \
       "module has no ActionController surface" do
      expect do
        Module.new do
          extend Ruact::ServerAction

          def self.name
            "FrameworkResvHost"
          end

          ruact_action(:params) { |_p| nil }
        end
      end.not_to raise_error
    end

    it "Story 8.3 review R4 — rejects Class hosts at first ruact_action call with a " \
       "documented Ruact::ConfigurationError pointing the dev to `include Ruact::Controller`" do
      klass = Class.new do
        extend Ruact::ServerAction

        def self.name
          "WronglyExtendedClass"
        end
      end

      expect do
        klass.class_eval { ruact_action(:bad_host) { |_p| nil } }
      end.to raise_error(Ruact::ConfigurationError) do |error|
        expect(error.message).to include("WronglyExtendedClass")
        expect(error.message).to include("standalone HOST MODULES")
        expect(error.message).to include("include Ruact::Controller")
      end
    end

    it "does NOT install a method_added hook — a later `def` on the host module does not " \
       "raise (standalone modules don't define action methods at all)" do
      expect do
        Module.new do
          extend Ruact::ServerAction

          def self.name
            "MethodAddedHost"
          end

          ruact_action(:registered_action) { |_p| nil }

          # A later method definition on the module would not trigger anything
          # — the registry holds the block; the module surface is irrelevant.
          define_method(:registered_action) { :unrelated_def }
        end
      end.not_to raise_error
    end
  end
end
