# frozen_string_literal: true

# Minimal Rails stub for specs that need Rails without it being in the bundle.
# Loaded automatically by spec_helper. Does nothing if Rails is already defined.
return if defined?(Rails)

# Prevent `require "rails"` inside loaded files from failing.
$LOADED_FEATURES << "rails.rb" unless $LOADED_FEATURES.any? { |f| f.end_with?("/rails.rb") }

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
