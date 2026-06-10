# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe Configuration do
    # Reset the singleton + boot flag around every example so order randomization
    # is safe and the warning-on-second-call contract can be exercised cleanly.
    # Save and restore the original Rails.logger so we never clobber a logger a
    # later randomized example expects to find in place.
    around do |example|
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      original_rails_logger = Rails.respond_to?(:logger) ? Rails.logger : nil
      example.run
    ensure
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Rails.logger = original_rails_logger if Rails.respond_to?(:logger=)
    end

    # Default: silence the [ruact] re-configuration warning so unrelated specs
    # that legitimately call Ruact.configure twice do not pollute stderr.
    # The "re-configuration warning" describe overrides this with its own assertions.
    before do
      Rails.singleton_class.send(:attr_accessor, :logger) unless Rails.respond_to?(:logger=)
      Rails.logger = instance_double(::Logger, warn: nil)
    end

    describe ".configure freezes the configuration" do
      it "is frozen the moment the configure block returns (AC1)" do
        Ruact.configure { |c| c.suspense_timeout = 7.0 }
        expect(Ruact.config).to be_frozen
      end

      it "preserves attribute reads after freeze (AC1)" do
        Ruact.configure do |c|
          c.suspense_timeout     = 8.0
          c.strict_serialization = true
          c.vite_dev_server      = "http://localhost:9999"
          c.manifest_path        = "/tmp/manifest.json"
        end

        expect(Ruact.config.suspense_timeout).to eq(8.0)
        expect(Ruact.config.strict_serialization).to be(true)
        expect(Ruact.config.vite_dev_server).to eq("http://localhost:9999")
        expect(Ruact.config.manifest_path).to eq("/tmp/manifest.json")
      end
    end

    describe "post-boot mutation" do
      before { Ruact.configure { |c| c.suspense_timeout = 5.0 } }

      Configuration::ATTRIBUTES.each do |attr|
        it "raises Ruact::ConfigurationError when ##{attr} is assigned outside Ruact.configure (AC2)" do
          expect { Ruact.config.public_send("#{attr}=", "anything") }
            .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration##{attr}/)
        end
      end

      it "error message includes the AC2 verbatim suggested-fix sentence (AC2.3)" do
        expect { Ruact.config.suspense_timeout = 12.0 }
          .to raise_error(
            Ruact::ConfigurationError,
            include("Wrap the change in Ruact.configure { |c| c.suspense_timeout = ... } " \
                    "in config/initializers/ruact.rb and restart the process.")
          )
      end

      it "error message includes the design intent (AC2.4)" do
        expect { Ruact.config.suspense_timeout = 12.0 }
          .to raise_error(
            Ruact::ConfigurationError,
            /Story 7\.3.*runtime config drift/m
          )
      end
    end

    describe "deep-freeze of attribute values (AC2 — bypass guard)" do
      it "freezes mutable string values so in-place mutation cannot bypass the writer guard" do
        Ruact.configure { |c| c.manifest_path = +"/tmp/manifest.json" }

        expect(Ruact.config.manifest_path).to be_frozen
        expect { Ruact.config.manifest_path.replace("/tmp/elsewhere.json") }
          .to raise_error(FrozenError)
      end

      it "freezes vite_dev_server even when only defaults are used (AC5)" do
        # No configure block — first access publishes the default-frozen Configuration.
        expect(Ruact.config.vite_dev_server).to be_frozen
      end

      it "carries the deep-freeze invariant through atomic re-configuration" do
        Ruact.configure { |c| c.manifest_path = +"/tmp/first.json" }
        Ruact.configure { |c| c.suspense_timeout = 9.0 } # does NOT touch manifest_path

        # The second configure clones from the first; manifest_path retains the
        # frozen value, not a fresh mutable reference.
        expect(Ruact.config.manifest_path).to be_frozen
      end

      it "values are mutable inside the configure block; freeze happens only after the block returns (AC1)" do
        # AC1: "the DSL inside the block is unchanged. The freeze happens after
        # the block returns, not before." Deep-freeze of attribute values must
        # therefore happen at publication time, not at writer time — otherwise
        # a developer who in-place-mutates a value within the same configure
        # block (a documented Ruby idiom) would see a confusing FrozenError.
        captured_inside_block = nil

        Ruact.configure do |c|
          c.manifest_path = +"/tmp/a.json"
          captured_inside_block = c.manifest_path
          expect(captured_inside_block).not_to be_frozen
          c.manifest_path.replace("/tmp/b.json") # idiomatic in-place mutation, must work
          expect(c.manifest_path).to eq("/tmp/b.json")
        end

        # After the block returns, publication has deep-frozen the value.
        expect(Ruact.config.manifest_path).to eq("/tmp/b.json")
        expect(Ruact.config.manifest_path).to be_frozen
        expect { Ruact.config.manifest_path.replace("/tmp/c.json") }.to raise_error(FrozenError)
      end

      it "template-inherited values are mutable inside a second configure block (AC1, F9)" do
        # F9: After the first publication, the published config has deep-frozen
        # values. The second Ruact.configure call clones into a draft via
        # Configuration.new(template:); that draft must be unfrozen so the AC1
        # contract holds for re-configuration too — including idiomatic
        # in-place mutation of inherited values.
        Ruact.configure { |c| c.manifest_path = +"/tmp/a.json" }
        expect(Ruact.config.manifest_path).to be_frozen # baseline: first publication froze the value

        Ruact.configure do |c|
          expect(c.manifest_path).not_to be_frozen # draft cloned the value into an unfrozen dup
          c.manifest_path.replace("/tmp/b.json")   # idiomatic in-place mutation on inherited value
          expect(c.manifest_path).to eq("/tmp/b.json")
        end

        # After the second block returns, publication freezes the draft's value.
        expect(Ruact.config.manifest_path).to eq("/tmp/b.json")
        expect(Ruact.config.manifest_path).to be_frozen
      end
    end

    describe "public API surface (AC1, AC7, AC9 — F10)" do
      it "does not expose seal! on Ruact::Configuration" do
        # seal! is a private implementation detail invoked by Ruact.configure /
        # Ruact.config via __send__. The public API surface is the four
        # readers + their writers (only callable inside a configure block) —
        # nothing else. External callers reaching into Ruact.config.seal!
        # must hit NoMethodError, not silently re-freeze.
        Ruact.configure { |c| c.suspense_timeout = 5.0 }

        expect(described_class.public_instance_methods(false)).not_to include(:seal!)
        expect(Ruact.config).not_to respond_to(:seal!)
        expect { Ruact.config.seal! }.to raise_error(NoMethodError, /private method/)
      end

      it "exposes only the documented readers + writers on the public surface" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }

        public_attrs = described_class.public_instance_methods(false)
        expected     = Configuration::ATTRIBUTES + Configuration::ATTRIBUTES.map { |a| :"#{a}=" }

        expect(public_attrs.sort).to eq(expected.sort)
      end
    end

    describe "atomic re-configuration" do
      it "produces a frozen Configuration after both calls (AC3)" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }
        first_config = Ruact.config

        Ruact.configure { |c| c.suspense_timeout = 9.0 }
        second_config = Ruact.config

        expect(first_config).to be_frozen
        expect(second_config).to be_frozen
        expect(second_config).not_to equal(first_config)
        expect(second_config.suspense_timeout).to eq(9.0)
      end

      it "clones every attribute from the previous configuration (AC3)" do
        Ruact.configure do |c|
          c.suspense_timeout     = 7.5
          c.strict_serialization = true
        end

        Ruact.configure { |c| c.vite_dev_server = "http://localhost:8000" }

        # Attributes set in the first call must survive the second call.
        expect(Ruact.config.suspense_timeout).to eq(7.5)
        expect(Ruact.config.strict_serialization).to be(true)
        expect(Ruact.config.vite_dev_server).to eq("http://localhost:8000")
      end

      it "intermediate readers inside the second configure block see the OLD frozen config (AC3)" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }
        old_config = Ruact.config

        observed_inside_block = nil
        observed_timeout      = nil

        Ruact.configure do |draft|
          # While the block runs, Ruact.config still resolves to the OLD frozen
          # config; the draft is a separate object that is not yet swapped in.
          observed_inside_block = Ruact.config
          observed_timeout      = Ruact.config.suspense_timeout
          draft.suspense_timeout = 99.0
        end

        expect(observed_inside_block).to equal(old_config)
        expect(observed_timeout).to eq(5.0)
        expect(Ruact.config).not_to equal(old_config)
        expect(Ruact.config.suspense_timeout).to eq(99.0)
      end
    end

    describe "re-configuration warning" do
      let(:fake_logger) { instance_double(::Logger, warn: nil) }

      # Override the parent before-hook with a per-example fake we can assert on.
      before { Rails.logger = fake_logger }

      it "does NOT warn on the first Ruact.configure call (AC3)" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }
        expect(fake_logger).not_to have_received(:warn)
      end

      it "warns on the second Ruact.configure call (AC3)" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }
        Ruact.configure { |c| c.suspense_timeout = 9.0 }

        expect(fake_logger).to have_received(:warn).with(
          a_string_matching(/\[ruact\] Ruact\.configure called after boot at .+:\d+/)
        )
      end

      it "warns on Ruact.configure that follows default Ruact.config first access (AC3, F2 fix)" do
        # Default first-access publishes the frozen-default Configuration; that
        # publication counts as boot, so the next configure call must warn.
        Ruact.config
        Ruact.configure { |c| c.suspense_timeout = 9.0 }

        expect(fake_logger).to have_received(:warn).with(
          a_string_matching(/\[ruact\] Ruact\.configure called after boot/)
        )
      end
    end

    describe "Ruact::ConfigurationError" do
      it "is a subclass of Ruact::Error (AC6)" do
        expect(Ruact::ConfigurationError.ancestors).to include(Ruact::Error)
      end
    end

    describe "boot-time defaults" do
      it "freezes the default Configuration on first access (AC5)" do
        # No Ruact.configure call — first access goes through Ruact.config directly.
        expect(Ruact.config).to be_frozen
      end

      it "applies documented defaults when no configure block runs (AC5)" do
        config = Ruact.config

        expect(config.manifest_path).to be_nil
        expect(config.strict_serialization).to be(false)
        expect(config.suspense_timeout).to eq(5.0)
        expect(config.vite_dev_server).to eq("http://localhost:5173")
        expect(config.current_user_resolver).to be_nil
      end

      it "rejects post-boot mutation against the default-frozen instance (AC5)" do
        expect { Ruact.config.suspense_timeout = 10.0 }
          .to raise_error(Ruact::ConfigurationError)
      end
    end

    describe "Story 8.3 — current_user_resolver attribute", :story_8_3 do
      it "defaults to nil so apps without standalone actions never get a phantom resolver" do
        expect(Ruact.config.current_user_resolver).to be_nil
      end

      it "accepts a lambda inside Ruact.configure and exposes it after publication" do
        resolver = ->(env) { env["warden"]&.user }
        Ruact.configure { |c| c.current_user_resolver = resolver }
        expect(Ruact.config.current_user_resolver).to be(resolver)
      end

      it "is sealed by the standard freeze contract — direct mutation raises ConfigurationError" do
        Ruact.configure { |c| c.current_user_resolver = ->(_env) {} }
        expect { Ruact.config.current_user_resolver = ->(_env) { "other" } }
          .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration#current_user_resolver/)
      end

      it "is carried across atomic re-configuration (template clone)" do
        first = ->(_env) { :first }
        Ruact.configure { |c| c.current_user_resolver = first }
        Ruact.configure { |c| c.suspense_timeout = 6.0 } # untouched
        expect(Ruact.config.current_user_resolver).to be(first)
      end

      it "deep-freezes the resolver lambda at publication time (Story 8.3 review R6) — " \
         "identity is preserved AND `frozen?` reports true" do
        resolver = ->(_env) {}
        Ruact.configure { |c| c.current_user_resolver = resolver }
        expect(Ruact.config.current_user_resolver).to be(resolver)
        expect(Ruact.config.current_user_resolver).to be_frozen
      end
    end

    describe "Story 8.5 — max_upload_bytes attribute", :story_8_5 do
      it "defaults to 10 MB (10 * 1024 * 1024 bytes)" do
        expect(Ruact.config.max_upload_bytes).to eq(10 * 1024 * 1024)
      end

      it "accepts an Integer inside Ruact.configure" do
        Ruact.configure { |c| c.max_upload_bytes = 25 * 1024 * 1024 }
        expect(Ruact.config.max_upload_bytes).to eq(25 * 1024 * 1024)
      end

      it "accepts nil to disable the gem-side guard" do
        Ruact.configure { |c| c.max_upload_bytes = nil }
        expect(Ruact.config.max_upload_bytes).to be_nil
      end

      it "is sealed by the standard freeze contract — direct mutation raises ConfigurationError" do
        Ruact.configure { |c| c.max_upload_bytes = 5 * 1024 * 1024 }
        expect { Ruact.config.max_upload_bytes = 9_000_000 }
          .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration#max_upload_bytes/)
      end

      it "is carried across atomic re-configuration (template clone)" do
        Ruact.configure { |c| c.max_upload_bytes = 7 * 1024 * 1024 }
        Ruact.configure { |c| c.suspense_timeout = 6.0 }
        expect(Ruact.config.max_upload_bytes).to eq(7 * 1024 * 1024)
      end

      describe "writer-time validation (review patch)" do
        it "accepts 0 (a degenerate but legal cap that rejects every multipart/urlencoded request)" do
          expect { Ruact.configure { |c| c.max_upload_bytes = 0 } }.not_to raise_error
          expect(Ruact.config.max_upload_bytes).to eq(0)
        end

        it "rejects negative Integer with ConfigurationError" do
          expect { Ruact.configure { |c| c.max_upload_bytes = -1 } }
            .to raise_error(Ruact::ConfigurationError, /must be nil or a non-negative Integer/)
        end

        it "rejects String with ConfigurationError naming the offending value + class" do
          expect { Ruact.configure { |c| c.max_upload_bytes = "10485760" } }
            .to raise_error(Ruact::ConfigurationError, /got "10485760" \(String\)/)
        end

        it "rejects Float with ConfigurationError" do
          expect { Ruact.configure { |c| c.max_upload_bytes = 1024.0 } }
            .to raise_error(Ruact::ConfigurationError, /must be nil or a non-negative Integer/)
        end

        it "rejects Symbol with ConfigurationError" do
          expect { Ruact.configure { |c| c.max_upload_bytes = :unlimited } }
            .to raise_error(Ruact::ConfigurationError, /must be nil or a non-negative Integer/)
        end

        it "rejects true/false with ConfigurationError" do
          expect { Ruact.configure { |c| c.max_upload_bytes = true } }
            .to raise_error(Ruact::ConfigurationError, /must be nil or a non-negative Integer/)
        end
      end
    end

    describe "Story 8.4 — dev_error_payload_enabled attribute", :story_8_4 do
      it "defaults to nil so the endpoint controller can resolve to Rails env at request time" do
        expect(Ruact.config.dev_error_payload_enabled).to be_nil
      end

      it "accepts true inside Ruact.configure and exposes it after publication" do
        Ruact.configure { |c| c.dev_error_payload_enabled = true }
        expect(Ruact.config.dev_error_payload_enabled).to be(true)
      end

      it "accepts false inside Ruact.configure and exposes it after publication" do
        Ruact.configure { |c| c.dev_error_payload_enabled = false }
        expect(Ruact.config.dev_error_payload_enabled).to be(false)
      end

      it "is sealed by the standard freeze contract — direct mutation raises ConfigurationError" do
        Ruact.configure { |c| c.dev_error_payload_enabled = true }
        expect { Ruact.config.dev_error_payload_enabled = false }
          .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration#dev_error_payload_enabled/)
      end

      it "is carried across atomic re-configuration (template clone)" do
        Ruact.configure { |c| c.dev_error_payload_enabled = false }
        Ruact.configure { |c| c.suspense_timeout = 6.0 }
        expect(Ruact.config.dev_error_payload_enabled).to be(false)
      end
    end

    describe "Story 9.4 — query_route_prefix attribute", :story_9_4 do
      it "defaults to \"/q\"" do
        expect(Ruact.config.query_route_prefix).to eq("/q")
      end

      it "accepts a custom prefix inside Ruact.configure" do
        Ruact.configure { |c| c.query_route_prefix = "/api/queries" }
        expect(Ruact.config.query_route_prefix).to eq("/api/queries")
      end

      it "is sealed by the standard freeze contract — direct mutation raises ConfigurationError" do
        Ruact.configure { |c| c.query_route_prefix = "/q" }
        expect { Ruact.config.query_route_prefix = "/other" }
          .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration#query_route_prefix/)
      end

      it "is carried across atomic re-configuration (template clone)" do
        Ruact.configure { |c| c.query_route_prefix = "/internal/q" }
        Ruact.configure { |c| c.suspense_timeout = 6.0 }
        expect(Ruact.config.query_route_prefix).to eq("/internal/q")
      end

      describe "writer-time validation" do
        it "rejects a non-String with ConfigurationError naming the offending value + class" do
          expect { Ruact.configure { |c| c.query_route_prefix = :q } }
            .to raise_error(Ruact::ConfigurationError, /got :q \(Symbol\)/)
        end

        it "rejects a prefix that does not start with \"/\"" do
          expect { Ruact.configure { |c| c.query_route_prefix = "q" } }
            .to raise_error(Ruact::ConfigurationError, %r{must be a String starting with "/"})
        end

        it "rejects a prefix with a trailing slash (the macro joins with \"/\")" do
          expect { Ruact.configure { |c| c.query_route_prefix = "/q/" } }
            .to raise_error(Ruact::ConfigurationError, %r{must not end with "/"})
        end

        it "rejects nil" do
          expect { Ruact.configure { |c| c.query_route_prefix = nil } }
            .to raise_error(Ruact::ConfigurationError, %r{must be a String starting with "/"})
        end
      end
    end

    describe "Story 9.4 — query_parent_controller attribute", :story_9_4 do
      it "defaults to \"ApplicationController\"" do
        expect(Ruact.config.query_parent_controller).to eq("ApplicationController")
      end

      it "accepts a custom controller name inside Ruact.configure" do
        Ruact.configure { |c| c.query_parent_controller = "Api::BaseController" }
        expect(Ruact.config.query_parent_controller).to eq("Api::BaseController")
      end

      it "is sealed by the standard freeze contract — direct mutation raises ConfigurationError" do
        Ruact.configure { |c| c.query_parent_controller = "ApplicationController" }
        expect { Ruact.config.query_parent_controller = "Other" }
          .to raise_error(Ruact::ConfigurationError, /Ruact::Configuration#query_parent_controller/)
      end

      it "is carried across atomic re-configuration (template clone)" do
        Ruact.configure { |c| c.query_parent_controller = "Api::BaseController" }
        Ruact.configure { |c| c.suspense_timeout = 6.0 }
        expect(Ruact.config.query_parent_controller).to eq("Api::BaseController")
      end

      describe "writer-time validation" do
        it "rejects a Class with ConfigurationError (the name is constantized lazily at route-draw time)" do
          expect { Ruact.configure { |c| c.query_parent_controller = Class.new } }
            .to raise_error(Ruact::ConfigurationError, /must be a non-empty String/)
        end

        it "rejects an empty String" do
          expect { Ruact.configure { |c| c.query_parent_controller = "" } }
            .to raise_error(Ruact::ConfigurationError, /must be a non-empty String/)
        end

        it "rejects nil" do
          expect { Ruact.configure { |c| c.query_parent_controller = nil } }
            .to raise_error(Ruact::ConfigurationError, /must be a non-empty String/)
        end
      end
    end

    describe "error message includes caller location" do
      it "names the file:line of the offending mutation (AC2.2)" do
        Ruact.configure { |c| c.suspense_timeout = 5.0 }

        # Capture the file:line of the next line via __FILE__ / __LINE__.
        expected_path = __FILE__
        expected_line = __LINE__ + 2
        expect do
          Ruact.config.suspense_timeout = 99.0
        end.to raise_error(
          Ruact::ConfigurationError,
          a_string_matching(/Attempted at: #{Regexp.escape(expected_path)}:#{expected_line}/)
        )
      end
    end
  end
end
