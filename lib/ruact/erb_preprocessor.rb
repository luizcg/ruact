# frozen_string_literal: true

module Ruact
  # Transforms ERB source before Ruby evaluation.
  #
  # It handles one thing: PascalCase component tags with +{expr}+ props.
  #
  #   <LikeButton postId={@post.id} initialCount={5} />
  #
  # becomes a placeholder that evaluates the props as Ruby:
  #
  #   <%= __ruact_component__("LikeButton", { "postId" => @post.id, "initialCount" => 5 }) %>
  #
  # The placeholder is replaced by an HTML comment with a unique token:
  #   <!-- __RUACT_0__ -->
  #
  # A component with children (Story 18-2) keeps its content as ERB, inside a
  # wrapper element HtmlConverter turns into the component's `children`:
  #
  #   <Card title={@t}><p><%= @body %></p></Card>
  #   → <%= __ruact_component_open__("Card", { "title" => @t }) %><p><%= @body %></p></ruact-component>
  #
  # The actual ClientReference + props are registered in the binding and
  # collected by HtmlConverter after the ERB renders.
  class ErbPreprocessor # rubocop:disable Metrics/ClassLength
    # Matches a PascalCase opening tag with optional attributes and optional self-closing.
    # Examples:
    #   <Button />
    #   <LikeButton postId={@post.id} initialCount={5} />
    #   <Card title={@post.title}>
    COMPONENT_TAG_RE = %r{<([A-Z][A-Za-z0-9]*)(\s[^>]*)?\s*/?>}

    # Matches <Suspense ...> opening tags (handled before general PascalCase processing).
    SUSPENSE_OPEN_RE  = /<Suspense\b([^>]*?)>/m
    SUSPENSE_CLOSE_RE = %r{</Suspense\s*>}

    # Matches ANY PascalCase component tag: opening (`<Card>`), self-closing
    # (`<Card />`), or closing (`</Card>`). Capture 1 is the leading slash
    # (present only on a closing tag); capture 2 is the name. The pairing scan
    # walks these left to right with one stack (Story 18-2).
    COMPONENT_ANY_TAG_RE = %r{<(/)?([A-Z][A-Za-z0-9]*)(?:\s[^>]*|/)?>}

    # Cheap allocation-free probe (`String#match?`) for "is there ANY PascalCase
    # closing tag at all?". Without one there is nothing to pair, so the
    # template takes the single-pass path; `</Suspense>` matches too — harmless.
    CLOSING_TAG_PROBE_RE = %r{</[A-Z][A-Za-z0-9]*[\s/>]}

    # Newline-preserving mask for ERB islands (`<% … %>`, `<%= … %>`, `<%# … %>`).
    # The pairing scan blanks these first so a `</Card>` that lives inside
    # Ruby/ERB string or comment text is never taken for a real closing tag.
    ERB_ISLAND_RE = /<%.*?%>/m

    # An ERB comment, which renders nothing.
    ERB_COMMENT_RE = /<%#.*?%>/m

    # The element a paired component's content is wrapped in until
    # {HtmlConverter} turns it into the component's `children`.
    WRAPPER_TAG = "ruact-component"

    # What each helper the transformed template calls leaves in the HTML, by
    # its render-context token: a component, or the opening of one with
    # children. {RenderPipeline} installs these for a plain-ERB render;
    # ViewHelper writes the same strings in ActionView.
    PLACEHOLDERS = {
      __ruact_component__: ->(token) { "<!-- #{token} -->" },
      __ruact_component_open__: ->(token) { %(<#{WRAPPER_TAG} data-ruact-token="#{token}">) }
    }.freeze

    # Transform ERB source, replacing component tags with ERB placeholders.
    # Returns the transformed source string.
    #
    # +identifier+ is the template path (forwarded by {ErbPreprocessorHook} as
    # +template.identifier+) so an error can name the call site's file:line.
    # +registry+ is the component contract source — an injectable seam (Story
    # 7.1 explicit-context grain); it defaults to the process-loaded
    # {Ruact.manifest}. Pass +registry: nil+ (or a stub) in specs to control
    # contract lookup; +nil+ forces fail-open (no validation).
    def self.transform(source, identifier: nil, registry: :default)
      new.transform(source, identifier: identifier, registry: registry)
    end

    def transform(source, identifier: nil, registry: :default)
      # NOTE: +registry+ stays the +:default+ sentinel here. It is resolved to
      # +Ruact.manifest+ LAZILY, only when a component tag exists — a source
      # with no PascalCase tags must touch the registry not at all (AC2/AC6
      # fast-path invariant).
      @identifier = identifier
      @registry   = registry

      # Step 1: component tags → ERB placeholders. Story 18-2: a tag with a
      # matching closing tag is a component WITH children; its content stays
      # ERB, evaluated in place, inside a wrapper element.
      result = if source.match?(CLOSING_TAG_PROBE_RE)
                 rewrite_paired(source)
               else
                 rewrite_self_closing(source)
               end

      # Step 2: <Suspense> paired tags → <ruact-suspense> HTML elements.
      result
        .gsub(SUSPENSE_OPEN_RE) do
          attrs    = ::Regexp.last_match(1)
          fallback = extract_string_attr(attrs, "fallback") || ""
          escaped  = fallback.gsub('"', "&quot;")
          # Optional `delay="2.5"` — the server-side wait (seconds) before
          # the deferred chunk streams. Forwarded to SuspenseElement#delay.
          delay      = extract_string_attr(attrs, "delay")
          delay_attr = delay ? %( data-ruact-delay="#{delay.gsub('"', '&quot;')}") : ""
          %(<ruact-suspense data-ruact-fallback="#{escaped}"#{delay_attr}>)
        end
        .gsub(SUSPENSE_CLOSE_RE, "</ruact-suspense>")
    end

    private

    # The common path: no PascalCase closing tag anywhere, so every component
    # tag should be self-closing. One gsub, no masking copies — the render
    # benchmark's allocation profile depends on it. An opening tag that is not
    # self-closing hands the whole template to {#rewrite_paired}, which masks
    # ERB: `<%# wrap in <Card> later %>` is a comment, not an unclosed tag.
    # So does any tag inside an ERB island (a commented-out component): the
    # paired path leaves those alone.
    def rewrite_self_closing(source)
      catch(:open_tag) do
        return source.gsub(COMPONENT_TAG_RE) do |match|
          name = ::Regexp.last_match(1)
          next match if name == "Suspense"

          throw :open_tag unless match.end_with?("/>")
          throw :open_tag if inside_erb?(source, ::Regexp.last_match.begin(0))

          placeholder(name, ::Regexp.last_match(2).to_s.strip, match,
                      line_at(source, ::Regexp.last_match.begin(0)), :self_closing)
        end
      end
      rewrite_paired(source)
    end

    # Story 18-2 — pair opening and closing tags with one stack over the
    # template with ERB islands and Suspense blanked (offsets preserved, so
    # every line reported is the template's own), then rewrite each tag in
    # place: a paired opening becomes {ViewHelper#__ruact_component_open__}'s
    # wrapper, its closing `</ruact-component>`, a self-closing tag the usual
    # placeholder. Tags inside ERB text are left alone.
    def rewrite_paired(source)
      scan   = mask_suspense(mask_erb(source))
      tags   = []
      stack  = []
      paired = {}

      scan.scan(COMPONENT_ANY_TAG_RE) do
        m = ::Regexp.last_match
        tag = { name: m[2], from: m.begin(0), to: m.end(0) }
        tags << tag

        if m[1] # a closing tag `</Name>`
          tag[:closing] = true
          open = stack.pop
          raise_stray(tag[:name], line_at(source, tag[:from])) if open.nil?
          # `<Card><Box></Card>`: the tag left open is the one to fix.
          raise_open_tag(source, open) unless open[:name] == tag[:name]

          # The value says whether anything sits between the tags: an empty
          # pair passes no children, like `<Card />`. Read from the template
          # itself — ERB between the tags (`<%= @body %>`) is content, an ERB
          # comment is not.
          paired[open[:from]] = !source[open[:to]...tag[:from]].gsub(ERB_COMMENT_RE, "").strip.empty?
        elsif !m[0].end_with?("/>")
          stack << tag
        end
      end
      raise_open_tag(source, stack.first) unless stack.empty?

      splice(source, tags, paired)
    end

    # +source+ with each tag replaced by its placeholder. +paired+ maps an
    # opening tag's offset to whether its pair holds anything.
    def splice(source, tags, paired)
      out    = +""
      cursor = 0
      tags.each do |tag|
        out << source[cursor...tag[:from]]
        out << rewrite_tag(source, tag, paired)
        cursor = tag[:to]
      end
      out << source[cursor..]
    end

    def rewrite_tag(source, tag, paired)
      return "</#{WRAPPER_TAG}>" if tag[:closing]

      kind = if !paired.key?(tag[:from]) then :self_closing
             elsif paired[tag[:from]] then :with_children
             else :empty_pair
             end
      text = source[tag[:from]...tag[:to]]
      placeholder(tag[:name], text.match(COMPONENT_TAG_RE)[2].to_s.strip, text, line_at(source, tag[:from]), kind)
    end

    # The ERB placeholder for one component tag. Props are parsed (and the
    # opt-in contract checked) here; a pair with content passes `children` too.
    # +kind+ is :self_closing, :empty_pair or :with_children.
    def placeholder(name, attrs_string, match, line, kind)
      children = kind == :with_children
      # lazy — only when a tag exists. `resolve_soft` returns the dev-fetched
      # manifest (same source the render path uses, so the boot-race doesn't
      # silence FR100 contract checks in dev) and FAILS OPEN to nil when the
      # manifest is unresolvable (contract validation is opt-in/fail-open; the
      # render path surfaces the clear error). In prod this is the boot-loaded
      # Ruact.manifest, unchanged.
      @registry = ManifestResolver.resolve_soft if @registry == :default
      pairs = ComponentAttributes.parse(attrs_string)
      names = pairs.map(&:first)
      raise_children_twice(name, line) if children && names.include?("children")

      check_known!(name, line)
      validate_contract(@registry, name, children ? names + ["children"] : names,
                        at: { file: @identifier, line: line, snippet: match.strip })
      props_ruby = pairs.map { |prop, expr| "#{prop.inspect} => #{expr}" }.join(", ")
      props_hash = props_ruby.empty? ? "{}" : "{ #{props_ruby} }"
      helper = kind == :self_closing ? "__ruact_component__" : "__ruact_component_open__"
      %(<%= #{helper}(#{name.inspect}, #{props_hash}) %>)
    rescue ComponentContractError, ComponentTagError, UnknownComponentError
      # Already carry file:line and the fix — re-raise AS-IS (do NOT append the
      # generic "at line N: snippet" tail).
      raise
    rescue PreprocessorError => e
      raise PreprocessorError, "#{e.message} at line #{line}: #{match.strip}"
    end

    # Story 18-2 — a component the manifest does not have fails here, with the
    # template's file:line, instead of at render with no location. Skipped
    # when there is no manifest to ask (fail open, like the contract check).
    def check_known!(name, line)
      return unless @registry.respond_to?(:component?)
      return if @registry.component?(name)

      message = @registry.unknown_component_message(name, controller_path: controller_path_from(@identifier))
      # With a close name on offer it is a typo; "did you run the Vite build?"
      # would send the reader the wrong way.
      message = message.lines.grep_v(/Did you run the Vite build/).join.rstrip if message.include?('Did you mean "')
      raise UnknownComponentError, message.sub(/\Aruact: /, "ruact: <#{name}> at #{location(line)} — ")
    end

    # Whether +offset+ sits inside an ERB island (`<% … %>`): the nearest `<%`
    # before it closes after it. One search back, one short search forward; no
    # allocation.
    def inside_erb?(source, offset)
      opened = source.rindex("<%", offset)
      return false unless opened

      closed = source.index("%>", opened + 2)
      closed.nil? || closed + 2 > offset
    end

    def line_at(source, offset)
      source[0...offset].count("\n") + 1
    end

    def location(line)
      @identifier ? "#{@identifier}:#{line}" : "line #{line}"
    end

    def raise_open_tag(source, tag)
      text = source[tag[:from]...tag[:to]]
      raise_unclosed(tag[:name], line_at(source, tag[:from]),
                     attrs: text.match(COMPONENT_TAG_RE)[2].to_s.strip, snippet: text)
    end

    # A tag that looks open may only be a `>` inside an attribute value
    # (`title="a > b"`, `title="<%= @t %>"`) cutting the tag short; the
    # attribute's own error says that, so it goes first.
    def raise_unclosed(name, line, attrs:, snippet:)
      begin
        ComponentAttributes.parse(attrs)
      rescue PreprocessorError => e
        raise PreprocessorError, "#{e.message} at line #{line}: #{snippet.strip}"
      end
      raise ComponentTagError,
            "ruact: <#{name}> at #{location(line)} is never closed — write `<#{name} ... />` for a " \
            "component without children, or close it with `</#{name}>`."
    end

    def raise_stray(name, line)
      raise ComponentTagError,
            "ruact: </#{name}> at #{location(line)} closes nothing — there is no open <#{name}> before it."
    end

    def raise_children_twice(name, line)
      raise ComponentTagError,
            "ruact: <#{name}> at #{location(line)} has content between its tags and a `children={...}` " \
            "prop — pass one of them."
    end

    # Blank out Suspense open/close tags while preserving EVERY newline and
    # byte offset, so the pairing scan neither sees `<Suspense>...</Suspense>`
    # nor mis-reports a line after a multi-line Suspense opening. Non-newline
    # chars → spaces (same length); newlines kept verbatim.
    def mask_suspense(source)
      source
        .gsub(SUSPENSE_OPEN_RE)  { |m| m.gsub(/[^\n]/, " ") }
        .gsub(SUSPENSE_CLOSE_RE) { |m| m.gsub(/[^\n]/, " ") }
    end

    # Blank ERB islands (position-faithful, see {mask_suspense}) so component
    # tags that appear only inside Ruby/ERB string or comment text are invisible
    # to the pairing scan.
    def mask_erb(source)
      source.gsub(ERB_ISLAND_RE) { |m| m.gsub(/[^\n]/, " ") }
    end

    # Extract a string attribute value (double or single quoted) from an attrs string.
    def extract_string_attr(attrs, name)
      m = attrs.match(/\b#{Regexp.escape(name)}\s*=\s*"([^"]*)"/) ||
          attrs.match(/\b#{Regexp.escape(name)}\s*=\s*'([^']*)'/)
      m&.[](1)
    end

    # Story 13.5 — run the opt-in contract check for +component_name+ against
    # the parsed call-site prop +names+. Looks the contract up through the
    # injected +registry+ seam and SKIPS ENTIRELY when there is none (no
    # registry, registry without +contract_for+, or no contract for this
    # component) — that is the AC2/AC6 fail-open path that keeps a contract-less
    # component byte-identical. Invoked ONLY inside the component-tag block, so
    # the no-tag fast path never reads the registry.
    def validate_contract(registry, component_name, names, at:)
      return unless registry.respond_to?(:contract_for)

      contract = registry.contract_for(component_name, controller_path: controller_path_from(at[:file]))
      return if contract.nil?

      ComponentContract.validate(
        component_name: component_name, prop_names: names, contract: contract, at: at
      )
    end

    # Best-effort controller_path from a template identifier so a co-located
    # component's contract resolves (e.g. ".../app/views/posts/show.html.erb"
    # → "posts"). A wrong/absent guess is harmless: {ClientManifest#resolve_key}
    # falls back to the shared PascalCase key.
    def controller_path_from(identifier)
      return nil unless identifier

      m = identifier.to_s.match(%r{app/views/(.+)/[^/]+\z})
      m && m[1]
    end
  end
end
