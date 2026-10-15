# frozen_string_literal: true

module Ruact
  # Per-render mutable state holding the components encountered during ERB
  # evaluation, and — in an action that streams — the `<Suspense>` blocks whose
  # content is rendered after the shell is sent. One instance is allocated by
  # the controller per render, passed explicitly through the pipeline, and
  # discarded when the response is sent.
  #
  # No shared state, no thread-local lookup — the instance lives only as long
  # as the render call. Satisfies NFR8 and the `Ruact/NoSharedState` cop with
  # zero exceptions in `lib/`.
  #
  # Internal API: not part of the public compatibility contract.
  class RenderContext
    # A `<Suspense>` block waiting to be rendered: the view it was written in,
    # the block, and the template Rails was rendering when it met the tag
    # (`t(".key")` and error messages read it).
    Block = Struct.new(:view, :block, :virtual_path, :template, :location)

    # @param deferring [Boolean] whether a `<Suspense>`'s content is rendered
    #   after the shell (an action that streams) instead of in place
    def initialize(deferring: false)
      @components = []
      @deferring  = deferring
      @blocks     = []
    end

    attr_reader :components

    # Whether a `<Suspense>`'s content is rendered after the shell.
    def deferring?
      @deferring
    end

    def register(name, props)
      # Frozen: the converter keys a Hash by it, which would copy an unfrozen one.
      token = "__RUACT_#{@components.length}__".freeze
      @components << { token: token, name: name, props: props }
      token
    end

    # Keeps a `<Suspense>` block for later and returns its index.
    #
    # @param block [Block]
    # @return [Integer]
    def defer_block(block)
      @blocks << block
      @blocks.length - 1
    end

    # The block registered under +index+.
    #
    # @return [Block]
    def block(index)
      @blocks.fetch(index)
    end

    # Whether the development message for a `<Suspense>` in an action that
    # does not stream was given in this render: once per response.
    def unstreamed_suspense_noted?
      @unstreamed_suspense_noted == true
    end

    def note_unstreamed_suspense!
      @unstreamed_suspense_noted = true
    end

    # The registered components with the client reference +manifest+ gives
    # each, in the shape {HtmlConverter} reads:
    # `[{ token:, name:, ref:, props: }, ...]`. Raises what the manifest raises
    # for a component it does not have. +from+ skips the first components (the
    # ones a previous call resolved).
    def resolve(manifest, controller_path: nil, from: 0)
      entries = from.zero? ? @components : @components.drop(from)
      entries.map { |entry| resolve_entry(entry, manifest, controller_path: controller_path) }
    end

    # One registered component, resolved as {#resolve} does.
    def resolve_entry(entry, manifest, controller_path: nil)
      ref = manifest.reference_for(entry[:name], controller_path: controller_path)
      { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
    end
  end
end
