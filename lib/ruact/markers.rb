# frozen_string_literal: true

module Ruact
  # Internal — what an evaluated template leaves in its HTML for
  # {HtmlConverter} to turn into React elements: the protocol between
  # evaluating a template and converting it.
  #
  # Three markers:
  #
  # - a client component: an HTML comment holding the token its
  #   {RenderContext} entry was registered under — `<!-- __RUACT_a1b2c3d4_0__ -->`;
  # - a client component with children: an element wrapped around the
  #   children's HTML — `<ruact-component data-ruact-token="__RUACT_a1b2c3d4_0__">…`;
  # - a Suspense boundary: an element wrapped around its content, carrying the
  #   fallback text and the optional delay —
  #   `<ruact-suspense data-ruact-fallback="Loading…">…</ruact-suspense>`. A
  #   boundary whose content is rendered later is empty and carries the key
  #   of its block in the {RenderContext} instead (`data-ruact-block="a1b2c3d4-0"`).
  #
  # Every token and key carries the id of the render that wrote it, so a
  # marker a `cache` block stored in another render is never taken for one of
  # this render's.
  #
  # {ErbPreprocessor} writes the ERB that produces them, the view helpers
  # ({ViewHelper}, and {RenderPipeline} for a plain-ERB render) write the
  # component markers, {HtmlConverter} reads all three. None of them spells
  # these strings itself.
  module Markers
    # The element a paired component's content is wrapped in.
    WRAPPER_TAG = "ruact-component"
    WRAPPER_CLOSE = "</#{WRAPPER_TAG}>".freeze

    # The element a Suspense boundary's content is wrapped in.
    SUSPENSE_TAG = "ruact-suspense"
    SUSPENSE_CLOSE = "</#{SUSPENSE_TAG}>".freeze

    TOKEN_ATTR    = "data-ruact-token"
    FALLBACK_ATTR = "data-ruact-fallback"
    DELAY_ATTR    = "data-ruact-delay"
    BLOCK_ATTR    = "data-ruact-block"

    # The marker for a client component, by its render-context token.
    def self.component(token)
      "<!-- #{token} -->"
    end

    # The opening of a client component with children; {WRAPPER_CLOSE} ends it.
    def self.component_open(token)
      %(<#{WRAPPER_TAG} #{TOKEN_ATTR}="#{token}">)
    end

    # The opening of a Suspense boundary, from the `fallback` and `delay`
    # attribute values as written in the template. Only `"` is escaped: the
    # rest of the text stays as the template wrote it (entities included, which
    # the HTML parser then decodes). The preprocessor refuses ERB in either.
    # +block+ is the key of the boundary's content in the render context,
    # when that content is rendered later.
    def self.suspense_open(fallback, delay, block: nil)
      delay_attr = delay ? %( #{DELAY_ATTR}="#{delay.gsub('"', '&quot;')}") : ""
      block_attr = block ? %( #{BLOCK_ATTR}="#{block}") : ""
      %(<#{SUSPENSE_TAG} #{FALLBACK_ATTR}="#{fallback.gsub('"', '&quot;')}"#{delay_attr}#{block_attr}>)
    end

    # The token a component marker (an HTML comment node) carries.
    def self.comment_token(node)
      node.content.strip
    end

    # The token a component-with-children wrapper carries.
    def self.wrapper_token(node)
      node[TOKEN_ATTR]
    end

    # The fallback text of a Suspense wrapper ("" when there is none).
    def self.suspense_fallback(node)
      node[FALLBACK_ATTR] || ""
    end

    # The key of the block a Suspense wrapper's content is rendered from
    # later, or nil when the content is in the wrapper.
    def self.suspense_block(node)
      node[BLOCK_ATTR]
    end

    # The delay of a Suspense wrapper, in seconds, or nil when it is absent,
    # blank, unparseable or not finite (`"1e309"` parses to Infinity without
    # raising, and must not reach a `sleep`).
    def self.suspense_delay(node)
      value = node[DELAY_ATTR]
      return nil if value.nil? || value.to_s.strip.empty?

      parsed = Float(value)
      parsed.finite? ? parsed : nil
    rescue ArgumentError, TypeError
      nil
    end
  end
end
