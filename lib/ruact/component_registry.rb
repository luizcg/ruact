# frozen_string_literal: true

module Ruact
  # Holds the client components encountered during ERB rendering.
  # Thread-local so it's safe under concurrent requests.
  module ComponentRegistry
    THREAD_KEY = :__rsc_component_registry__

    def self.start
      Thread.current[THREAD_KEY] = [] # rubocop:disable Ruact/NoSharedState -- TODO: refactor to explicit arg passing (NFR8)
    end

    def self.register(name, props)
      token = "__RSC_#{components.length}__"
      components << { token: token, name: name, props: props }
      token
    end

    def self.components
      Thread.current[THREAD_KEY] ||= [] # rubocop:disable Ruact/NoSharedState -- TODO: refactor to explicit arg passing (NFR8)
    end

    def self.reset
      Thread.current[THREAD_KEY] = nil # rubocop:disable Ruact/NoSharedState -- TODO: refactor to explicit arg passing (NFR8)
    end

    def self.by_token(token)
      components.find { |c| c[:token] == token }
    end
  end
end
