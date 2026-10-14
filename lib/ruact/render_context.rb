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
      # Frozen: the converter keys a Hash by it, which would copy an unfrozen one.
      token = "__RUACT_#{@components.length}__".freeze
      @components << { token: token, name: name, props: props }
      token
    end

    # The registered components with the client reference +manifest+ gives
    # each, in the shape {HtmlConverter} reads:
    # `[{ token:, name:, ref:, props: }, ...]`. Raises what the manifest raises
    # for a component it does not have.
    def resolve(manifest, controller_path: nil)
      @components.map do |entry|
        ref = manifest.reference_for(entry[:name], controller_path: controller_path)
        { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
      end
    end
  end
end
