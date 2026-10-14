# frozen_string_literal: true

require "ripper"

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

    # Any Suspense tag: capture 1 is the slash of a closing tag, capture 2 the
    # attributes, capture 3 the slash of a self-closing one.
    SUSPENSE_TAG_RE = %r{<(/)?Suspense\b([^>]*?)(/)?>}m

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
    # `<%%` is ERB's escape for a literal `<%`: text, not an island.
    ERB_ISLAND_RE = /<%(?!%).*?%>/m

    # An ERB comment, which renders nothing.
    ERB_COMMENT_RE = /<%#.*?%>/m

    # What ends a `<Suspense>`: the {ViewHelper#__ruact_suspense__} block its
    # content is the body of. The empty output tag after it keeps Rails' ERB
    # from trimming a `</Suspense>` that sits alone on its line, which would eat
    # the line break after it (text the page shows).
    SUSPENSE_BLOCK_CLOSE = %(<% end %><%= "" %>)

    # Ripper node types inside which `break`, `next`, `return`, `it` and `_1`
    # belong to a block or a loop of their own, not to the Suspense's block.
    OWN_SCOPE_NODES = %i[brace_block do_block while until while_mod until_mod for lambda def defs class module
                         sclass].freeze

    # One ERB tag's flag (`=`, `==`, `-`, or `#` for a comment) and its Ruby code.
    ERB_CODE_RE = /<%(?!%)(==|=|-|#)?(.*?)-?%>/m

    # What each helper the transformed template calls leaves in the HTML, by
    # its render-context token: a component, or the opening of one with
    # children ({Markers}). {RenderPipeline} installs these for a plain-ERB
    # render; ViewHelper writes the same markers in ActionView.
    PLACEHOLDERS = {
      __ruact_component__: ->(token) { Markers.component(token) },
      __ruact_component_open__: ->(token) { Markers.component_open(token) }
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
      # Suspense pairs are checked on the template as written, so an error names
      # the template's own line.
      check_suspense!(source) if source.include?("Suspense")

      result = if source.match?(CLOSING_TAG_PROBE_RE)
                 rewrite_paired(source)
               else
                 rewrite_self_closing(source)
               end

      rewrite_suspense(result)
    end

    private

    # Step 2: `<Suspense>` pairs. Each pair becomes a
    # {ViewHelper#__ruact_suspense__} call whose block is what sits between the
    # tags; the helper writes the Suspense marker around it ({Markers}), and
    # decides when the block is evaluated. `delay="2.5"` is optional: the
    # server-side wait (seconds) before the deferred chunk streams, forwarded to
    # SuspenseElement#delay. `<Suspense ... />` is a pair with nothing in it. A
    # tag inside an ERB island is Ruby text and is left alone. The generated ERB
    # keeps the tag's line breaks, so later lines keep their numbers.
    def rewrite_suspense(source)
      return source unless source.include?("Suspense")

      out = +""
      cursor = 0
      suspense_tags(source).each do |tag|
        out << source[cursor...tag[:from]]
        out << rewrite_suspense_tag(tag, source[tag[:from]...tag[:to]].count("\n"))
        cursor = tag[:to]
      end
      out << source[cursor..]
    end

    # Every Suspense tag outside an ERB island, in order.
    def suspense_tags(source)
      tags = []
      mask_erb(source).scan(SUSPENSE_TAG_RE) do
        m = ::Regexp.last_match
        kind = if m[1] then :close
               elsif m[3] then :empty
               else :open
               end
        tags << { kind: kind, from: m.begin(0), to: m.end(0), attrs: source[m.begin(2)...m.end(2)] }
      end
      tags
    end

    # Every `<Suspense>` has its `</Suspense>` (as a component tag does, Story
    # 18-2), in the same ERB block — the helper call it becomes opens a Ruby
    # block that the closing tag ends — and takes literal attribute values.
    # Raises {ComponentTagError} / {PreprocessorError} with the line.
    def check_suspense!(source)
      open = []
      suspense_tags(source).each do |tag|
        case tag[:kind]
        when :open then open << tag
        when :close
          opening = open.pop
          raise_stray("Suspense", line_at(source, tag[:from])) if opening.nil?
          check_same_block!(source, opening, tag)
        end
        check_literal_attributes!(source, tag) unless tag[:kind] == :close
      end
      return if open.empty?

      raise ComponentTagError,
            "ruact: <Suspense> at #{location(line_at(source, open.first[:from]))} is never closed — close it with " \
            "`</Suspense>`."
    end

    # The Ruby of the ERB tags between a pair has to stand on its own: an `if`
    # or a block opened or closed between them would take the pair's `end`.
    # Parsed inside parentheses, which no `end` in it can close, within a
    # method and a block, where `yield`, `next` and `return` are Ruby. When the
    # template's Ruby does not parse at all, Rails reports that, with its line.
    #
    # The content is then the body of a block, so `break`, `next`, `return`,
    # `it` and `_1` written at its own level would apply to that block, not to
    # the loop or block around the Suspense: refused, with what to do instead.
    def check_same_block!(source, opening, closing)
      tree = parse_erb_code(source[opening[:to]...closing[:from]])
      if tree.nil?
        return if parse_erb_code(source).nil?

        raise ComponentTagError,
              "ruact: <Suspense> at #{location(line_at(source, opening[:from]))} and its </Suspense> at line " \
              "#{line_at(source, closing[:from])} are not in the same ERB block — an `if`, a loop or a block opens " \
              "or closes between them. Put both tags inside that block, or both outside it."
      end

      word = escaping_word(first_node(tree, :paren))
      return unless word

      advice = %w[break next return].include?(word) ? "Move it outside the Suspense." : "Name the block's parameter."
      raise ComponentTagError,
            "ruact: <Suspense> at #{location(line_at(source, opening[:from]))} — `#{word}` between its tags would " \
            "apply to the Suspense's own block, not to the loop or block around it. #{advice}"
    end

    # The Ripper tree of the Ruby in +erb+'s tags (comments left out), as the
    # body of a block in a method, in parentheses; nil when it does not parse.
    def parse_erb_code(erb)
      code = erb.to_enum(:scan, ERB_CODE_RE).filter_map do
        m = ::Regexp.last_match
        m[2] unless m[1] == "#"
      end
      Ripper.sexp("def __ruact_check\nproc do\n(\n#{code.join("\n")}\n)\nend\nend")
    end

    # The first node of +type+ in +tree+, depth first: for {#parse_erb_code}'s
    # tree, the parentheses the template's code sits in.
    def first_node(tree, type)
      return nil unless tree.is_a?(Array)
      return tree if tree.first == type

      tree.each do |child|
        found = first_node(child, type)
        return found if found
      end
      nil
    end

    # The first `break`, `next`, `return`, implicit `it` or numbered parameter
    # at the parsed code's own level, if any.
    def escaping_word(node)
      return nil unless node.is_a?(Array)
      return nil if OWN_SCOPE_NODES.include?(node.first)

      case node.first
      when :break, :next, :return, :return0 then return node.first == :return0 ? "return" : node.first.to_s
      when :vcall then return "it" if node.dig(1, 1) == "it"
      when :var_ref then return node.dig(1, 1) if node.dig(1, 1).to_s.match?(/\A_[1-9]\z/)
      end
      node.each do |child|
        found = escaping_word(child)
        return found if found
      end
      nil
    end

    def check_literal_attributes!(source, tag)
      return unless tag[:attrs].include?("<%") || tag[:attrs].include?("%>")

      raise PreprocessorError,
            "ruact: <Suspense> at #{location(line_at(source, tag[:from]))} — `fallback` and `delay` take literal " \
            "text, not ERB."
    end

    def rewrite_suspense_tag(tag, line_breaks)
      breaks = "\n" * line_breaks
      return %(<% end #{breaks}%><%= "" %>) if tag[:kind] == :close

      fallback = extract_string_attr(tag[:attrs], "fallback") || ""
      delay    = extract_string_attr(tag[:attrs], "delay")
      opening  = %(<%= __ruact_suspense__(#{fallback.inspect}, #{delay.inspect}) do #{breaks}%>)
      tag[:kind] == :empty ? opening + SUSPENSE_BLOCK_CLOSE : opening
    end

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
      return Markers::WRAPPER_CLOSE if tag[:closing]

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
      # `<%%` is a literal `<%`, not an island: look further back.
      opened = opened.positive? ? source.rindex("<%", opened - 1) : nil while opened && source[opened + 2] == "%"
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
