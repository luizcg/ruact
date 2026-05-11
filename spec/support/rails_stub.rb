# frozen_string_literal: true

# Spec-only Rails bootstrap for tests that need a `Rails` constant. Two modes:
#
# 1. **Augment** (default since Story 7.9): when the `rails` gem is in the
#    bundle, load its core (`rails.rb` — just `Rails::VERSION`,
#    `Rails::Railtie`, `ActiveSupport::StringInquirer`, etc., *not*
#    `action_controller` / `action_view`) and add test-only writers
#    (`Rails.root=`, `Rails.env=`, `Rails.logger=`) on top. Specs that need
#    the full Rails request cycle (e.g. controller_request_spec.rb) require
#    `action_controller/railtie` and `action_view/railtie` themselves — the
#    rest of the suite never pays that cost.
#
# 2. **Full stub** (fallback): when `rails` is not in the bundle (e.g. a
#    matrix run that pruned it), provide a minimal `Rails` module + a
#    `Rails::Railtie` class with no-op class methods so `gem/lib/ruact/railtie.rb`
#    can `class Railtie < Rails::Railtie` without crashing. `$LOADED_FEATURES`
#    is patched so `require "rails"` inside loaded files no-ops.
#
# Loaded automatically by spec_helper.
#
# Augmentation is idempotent (each `Rails.define_singleton_method` is guarded
# by `unless Rails.singleton_class.method_defined?(...)`), so we run through
# this file every time it loads — even when Rails was already required by
# another spec file (e.g. controller_request_spec.rb pre-loads
# `action_controller/railtie`). Skipping with `return if defined?(Rails)`
# would leave doctor_spec / railtie_spec without the test-only writers when
# the request spec runs first.

unless defined?(Rails)
  begin
    # Loads Rails core only — not the request-cycle subsystem. Cheap.
    require "rails"
  rescue LoadError
    # Rails not available; fall through to the full stub below.
  end
end

if defined?(Rails) && Rails.respond_to?(:application)
  # Augment-mode: real Rails is present. Add test-only writers that the
  # existing suite (doctor_spec, railtie_spec) relies on, without clobbering
  # real Rails's behaviour outside the test override.
  unless Rails.singleton_class.method_defined?(:root=)
    original_root = Rails.method(:root) if Rails.respond_to?(:root)

    Rails.define_singleton_method(:root=) { |v| @_test_root = v }
    Rails.define_singleton_method(:root) do
      return @_test_root if defined?(@_test_root) && @_test_root

      original_root&.call
    end
  end

  unless Rails.singleton_class.method_defined?(:env=)
    Rails.define_singleton_method(:env=) { |v| @_test_env = v }
    original_env = Rails.method(:env) if Rails.respond_to?(:env)
    Rails.define_singleton_method(:env) do
      return @_test_env if defined?(@_test_env) && @_test_env

      original_env ? original_env.call : ActiveSupport::StringInquirer.new("test")
    end
  end

  unless Rails.singleton_class.method_defined?(:logger=)
    Rails.define_singleton_method(:logger=) { |v| @_test_logger = v }
    original_logger = Rails.method(:logger) if Rails.respond_to?(:logger)
    Rails.define_singleton_method(:logger) do
      return @_test_logger if defined?(@_test_logger) && @_test_logger

      original_logger&.call
    end
  end

  return
end

# Full-stub fallback: rails gem is not in the bundle.
$LOADED_FEATURES << "rails.rb"

module Rails
  class Railtie
    def self.initializer(*, **); end
    def self.rake_tasks(&); end

    def self.config
      @config ||= Class.new do
        def method_missing(name, *, **, &); end

        def respond_to_missing?(*, **)
          true
        end
      end.new
    end
  end

  class << self
    attr_accessor :env, :logger, :root
  end
end

module ActiveSupport # rubocop:disable Style/OneClassPerFile
  class StringInquirer < String
    def method_missing(method_name, *args)
      if method_name.to_s.end_with?("?")
        self == method_name.to_s.chomp("?")
      else
        super
      end
    end

    def respond_to_missing?(*, **)
      true
    end
  end
end
