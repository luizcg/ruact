# frozen_string_literal: true

require_relative "ruact/version"
require_relative "ruact/errors"
require_relative "ruact/configuration"
require_relative "ruact/serializable"
require_relative "ruact/flight"
require_relative "ruact/erb_preprocessor"
require_relative "ruact/component_registry"
require_relative "ruact/html_converter"
require_relative "ruact/client_manifest"
require_relative "ruact/render_pipeline"
require_relative "ruact/view_helper"
require_relative "ruact/erb_preprocessor_hook"
# Railtie loads ruact/controller when inside a Rails app
require_relative "ruact/railtie" if defined?(Rails)

module Ruact
  class << self
    attr_accessor :manifest, :streaming_mode

    # Returns the absolute path to the Vite plugin bundled inside this gem.
    # Use this in vite.config.js: import ruact from '<%= Ruact.vite_plugin_path %>'
    # Re-run `rails generate ruact:install` after gem upgrades to refresh the path.
    #
    # @return [String] absolute path to vendor/javascript/vite-plugin-ruact/index.js
    def vite_plugin_path
      File.expand_path("../vendor/javascript/vite-plugin-ruact/index.js", __dir__)
    end

    # Yields the configuration object for block-style setup.
    #
    # @example
    #   Ruact.configure do |config|
    #     config.strict_serialization = true
    #   end
    def configure
      yield config
    end

    # Returns the singleton configuration instance.
    #
    # @return [Ruact::Configuration]
    def config
      @config ||= Configuration.new
    end
  end
end
