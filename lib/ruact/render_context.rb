# frozen_string_literal: true

require "securerandom"

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
      # Story 19-2 — every marker this render writes carries it, so a marker a
      # `cache` block stored in another render never passes for one of this
      # render's: it would name another component, or another boundary's block.
      @id = SecureRandom.hex(4)
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
      token = "__RUACT_#{@id}_#{@components.length}__".freeze
      @components << { token: token, name: name, props: props }
      token
    end

    # Keeps a `<Suspense>` block for later and returns its key.
    #
    # @param block [Block]
    # @return [String]
    def defer_block(block)
      @blocks << block
      "#{@id}-#{@blocks.length - 1}".freeze
    end

    # The block registered under +key+, or nil when the key is not this
    # render's — a marker that came out of a `cache` block another render wrote.
    #
    # @return [Block, nil]
    def block(key)
      id, index = key.to_s.split("-", 2)
      return nil unless id == @id && index.to_s.match?(/\A\d+\z/)

      @blocks[Integer(index, 10)]
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
