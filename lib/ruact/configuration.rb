# frozen_string_literal: true

module Ruact
  # Holds gem-wide configuration. Instantiated once via Ruact.config.
  # Configure via Ruact.configure { |c| c.attr = value } in an initializer.
  class Configuration
    # @return [String, nil] Path to react-client-manifest.json.
    #   Defaults to Rails.root.join("public/react-client-manifest.json") when nil.
    attr_accessor :manifest_path

    # @return [Boolean] When true, objects without explicit rsc_props declaration
    #   raise Ruact::SerializationError. Defaults to false in development, true in production.
    attr_accessor :strict_serialization

    # @return [Float] Seconds before a deferred Suspense chunk times out. Default: 5.0.
    attr_accessor :suspense_timeout

    # @return [String] Base URL of the Vite dev server. Default: "http://localhost:5173".
    attr_accessor :vite_dev_server

    def initialize
      @manifest_path        = nil
      @strict_serialization = begin
        Rails.env.production?
      rescue StandardError
        false
      end
      @suspense_timeout     = 5.0
      @vite_dev_server      = "http://localhost:5173"
    end
  end
end
