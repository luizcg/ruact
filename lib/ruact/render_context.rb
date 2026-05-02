# frozen_string_literal: true

module Ruact
  # Per-render mutable state holding the components encountered during ERB
  # evaluation. One instance is allocated by the controller per render, passed
  # explicitly through the pipeline, and discarded when the response is sent.
  #
  # No shared state, no thread-local lookup — the instance lives only as long
  # as the render call. Satisfies NFR8 and the `Ruact/NoSharedState` cop with
  # zero exceptions in `lib/`.
  #
  # Internal API: not part of the public compatibility contract.
  class RenderContext
    def initialize
      @components = []
    end

    attr_reader :components

    def register(name, props)
      token = "__RSC_#{@components.length}__"
      @components << { token: token, name: name, props: props }
      token
    end

    def by_token(token)
      @components.find { |c| c[:token] == token }
    end
  end
end
