# frozen_string_literal: true

require_relative "ruact/version"
require_relative "ruact/errors"
require_relative "ruact/configuration"
require_relative "ruact/serializable"
require_relative "ruact/flight"
require_relative "ruact/erb_preprocessor"
require_relative "ruact/render_context"
require_relative "ruact/html_converter"
require_relative "ruact/client_manifest"
require_relative "ruact/render_pipeline"
require_relative "ruact/view_helper"
require_relative "ruact/erb_preprocessor_hook"
require_relative "ruact/server_functions"
require_relative "ruact/query"
# Railtie loads ruact/controller when inside a Rails app
require_relative "ruact/railtie" if defined?(Rails)

module Ruact
  class << self
    attr_accessor :manifest, :streaming_mode

    # Story 8.4 — Absolute path to the gem's `lib/` root. Used by
    # {Ruact::ServerFunctions::BacktraceCleaner} to classify backtrace frames as
    # APP or GEM. Memoised at first call so the per-frame `start_with?` check
    # stays constant-time. Anchors on this file's directory: `lib/ruact.rb`
    # resolves to `lib/` after `expand_path("..", __dir__)`.
    #
    # @return [String] absolute path to the gem's `lib/` directory
    def gem_path
      @gem_path ||= File.expand_path("..", __dir__)
    end

    # Returns the absolute path to the Vite plugin bundled inside this gem.
    # Use this in vite.config.js: import ruact from '<%= Ruact.vite_plugin_path %>'
    # Re-run `rails generate ruact:install` after gem upgrades to refresh the path.
    #
    # @return [String] absolute path to vendor/javascript/vite-plugin-ruact/index.js
    def vite_plugin_path
      File.expand_path("../vendor/javascript/vite-plugin-ruact/index.js", __dir__)
    end

    # Yields a mutable Configuration draft for block-style setup. The draft is
    # frozen and atomically swapped into `Ruact.config` when the block returns.
    # Mutating `Ruact.config` outside this block raises
    # `Ruact::ConfigurationError` (Story 7.3).
    #
    # When called a second time after boot, this method emits a `[ruact]`
    # warning advising that runtime re-configuration is unusual.
    #
    # @example
    #   Ruact.configure do |config|
    #     config.strict_serialization = true
    #   end
    # @yieldparam [Ruact::Configuration] mutable draft cloned from the current
    #   configuration (or built from defaults on first call)
    def configure
      draft = if defined?(@config) && @config
                Configuration.new(template: @config)
              else
                Configuration.new
              end

      yield draft

      warn_if_re_configuration!
      @config = draft.__send__(:seal!)
    end

    # Returns the singleton configuration instance, frozen on first access so
    # that mutation outside `Ruact.configure` always raises (Story 7.3).
    # First-access publication counts as the boot configuration, so a later
    # `Ruact.configure` call after default reads triggers the AC3 warning
    # (otherwise the warning would be silently bypassed in apps that never
    # call `Ruact.configure` at boot but reconfigure later).
    #
    # @return [Ruact::Configuration] frozen
    def config
      return @config if defined?(@config) && @config

      @config = Configuration.new.__send__(:seal!)
      @configured_at_least_once = true
      @config
    end

    private

    def warn_if_re_configuration!
      return unless @configured_at_least_once

      caller_loc = caller_locations(2, 1).first
      message = "[ruact] Ruact.configure called after boot at #{caller_loc.path}:#{caller_loc.lineno}. " \
                "Re-configuration at runtime is unusual and may indicate that configuration is being " \
                "driven by request state, environment, or feature flags rather than initializer-time invariants. " \
                "If this is intentional (e.g. test setup), ignore this warning; otherwise, consolidate " \
                "configuration into config/initializers/ruact.rb."

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        warn(message)
      end
    ensure
      @configured_at_least_once = true
    end
  end
end
