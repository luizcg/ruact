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
  # The actual ClientReference + props are registered in the binding and
  # collected by HtmlConverter after the ERB renders.
  class ErbPreprocessor
    # Matches a PascalCase opening tag with optional attributes and optional self-closing.
    # Examples:
    #   <Button />
    #   <LikeButton postId={@post.id} initialCount={5} />
    #   <Dialog open={true}>
    COMPONENT_TAG_RE = %r{<([A-Z][A-Za-z0-9]*)(\s[^>]*)?\s*/?>}

    # Matches <Suspense ...> opening tags (handled before general PascalCase processing).
    SUSPENSE_OPEN_RE  = /<Suspense\b([^>]*?)>/m
    SUSPENSE_CLOSE_RE = %r{</Suspense>}

    # Story 15.2 (FR106) — matches ANY PascalCase component tag: opening
    # (`<Card>`), self-closing (`<Card />`), or closing (`</Card>`). Capture 1 is
    # the leading slash (present only on a closing tag); capture 2 is the name.
    # The loud-children detection scans these left-to-right with a stack: an
    # opening pushes, a self-closing (`/>`) is ignored, and a closing that pops a
    # matching opening means that opening had children (paired usage) → loud
    # error. A single linear pass (no backreference/lazy backtracking) keeps the
    # component-dense fast path linear regardless of how many tags go unclosed.
    COMPONENT_ANY_TAG_RE = %r{<(/)?([A-Z][A-Za-z0-9]*)(?:\s[^>]*)?>}

    # Newline-preserving mask for ERB islands (`<% … %>`, `<%= … %>`, `<%# … %>`).
    # The loud-children scan blanks these first so a `</Card>` that lives inside
    # Ruby/ERB string or comment text can never be mistaken for a real component
    # closing tag (a valid bare `<Dialog>` opening must not error because some
    # unrelated `<% "</Dialog>" %>` appears later).
    ERB_ISLAND_RE = /<%.*?%>/m

    # Matches a +{ruby_expr}+ attribute value — captures everything between the braces.
    # We use a simple bracket-depth counter approach during scanning instead of regex
    # because expressions can contain nested braces: {foo.bar({ a: 1 })}.
    PROP_RE = /\b([a-zA-Z_][a-zA-Z0-9_]*)=\{/

    # Transform ERB source, replacing component tags with ERB placeholders.
    # Returns the transformed source string.
    #
    # +identifier+ is the template path (forwarded by {ErbPreprocessorHook} as
    # +template.identifier+) so a Story 13.5 contract violation can name the
    # call site's file:line. +registry+ is the component contract source — an
    # injectable seam (Story 7.1 explicit-context grain); it defaults to the
    # process-loaded {Ruact.manifest}. Pass +registry: nil+ (or a stub) in
    # specs to control contract lookup; +nil+ forces fail-open (no validation).
    def self.transform(source, identifier: nil, registry: :default)
      new.transform(source, identifier: identifier, registry: registry)
    end

    def transform(source, identifier: nil, registry: :default)
      # NOTE: +registry+ stays the +:default+ sentinel here. It is resolved to
      # +Ruact.manifest+ LAZILY, only inside the component-tag block below — a
      # source with no PascalCase tags must touch the registry not at all
      # (AC2/AC6 fast-path invariant).
      # Step 1: transform <Suspense> paired tags into <ruact-suspense> HTML elements.
      # This runs before the general component regex so Suspense isn't treated as a component.
      result = source
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

      # Step 1.5 (Story 15.2 / FR106): before the general component pass, fail
      # loudly if any PascalCase component tag is used with children (a matching
      # closing tag). Silent degradation of `<Card>Hello</Card>` — the #1
      # predictable JSX-habit mistake — becomes a self-contained, re-raised-as-is
      # PreprocessorError naming the fix. It scans the ORIGINAL +source+ (so
      # file:line is exact) and masks Suspense (the one legitimate paired
      # PascalCase tag) newline-for-newline, so `<Suspense>...</Suspense>` can
      # never trip and every reported line matches the template verbatim.
      detect_children!(source, identifier)

      # Step 2: transform remaining PascalCase self-closing / opening component tags.
      result.gsub(COMPONENT_TAG_RE) do |match|
        component_name = ::Regexp.last_match(1)
        attrs_string   = ::Regexp.last_match(2).to_s.strip
        match_start    = ::Regexp.last_match.begin(0)
        line           = result[0...match_start].count("\n") + 1

        begin
          # lazy — only when a tag exists. `resolve_soft` returns the dev-fetched
          # manifest (same source the render path uses, so the boot-race doesn't
          # silence FR100 contract checks in dev) and FAILS OPEN to nil when the
          # manifest is unresolvable (contract validation is opt-in/fail-open;
          # the render path surfaces the clear error). In prod this is the
          # boot-loaded Ruact.manifest, unchanged.
          registry = ManifestResolver.resolve_soft if registry == :default
          pairs = parse_prop_pairs(attrs_string)
          validate_contract(registry, component_name, pairs.map(&:first),
                            at: { file: identifier, line: line, snippet: match.strip })
          props_ruby = pairs.map { |name, expr| "#{name.inspect} => #{expr}" }.join(", ")
          props_hash = props_ruby.empty? ? "{}" : "{ #{props_ruby} }"
          %(<%= __ruact_component__(#{component_name.inspect}, #{props_hash}) %>)
        rescue ComponentContractError
          # Already carries file:line + offending prop + suggestion — re-raise
          # AS-IS (do NOT append the generic "at line N: snippet" tail).
          raise
        rescue PreprocessorError => e
          raise PreprocessorError, "#{e.message} at line #{line}: #{match.strip}"
        end
      end
    end

    private

    # Story 15.2 (FR106) — raise a loud, self-contained {ChildrenNotSupportedError}
    # on the FIRST PascalCase component tag used with children (a matching closing
    # tag). +source+ is the ORIGINAL template text; +identifier+ is the template
    # path (from {ErbPreprocessorHook}). Suspense — the one legitimate paired
    # PascalCase tag — is masked newline-for-newline first, so it never trips AND
    # every byte position (hence every reported line) still lines up with the raw
    # template. The line uses the same idiom as Step 2 (`count("\n") + 1`) on the
    # OPENING tag's offset. Message mirrors {ComponentContract.raise_error} shape
    # so both loud preprocess errors read identically. A no-op when no pair is
    # present — the fast path stays byte-identical.
    def detect_children!(source, identifier)
      # ERB islands first, then Suspense — both blank their text newline-for-
      # newline so byte offsets (hence reported lines) still match the raw
      # template, while neither ERB string text nor the legitimate Suspense pair
      # can be seen by the tag scan.
      scan = mask_suspense(mask_erb(source))
      # PER-NAME open stacks (name → [offsets]) so a closing tag checks for a
      # matching open in O(1) via `open_ats[name].last`, keeping the whole scan
      # linear even under thousands of stray/unmatched PascalCase closing tags
      # (a global stack + `rindex` was quadratic — Codex Round 3).
      open_ats = Hash.new { |h, k| h[k] = [] }

      scan.scan(COMPONENT_ANY_TAG_RE) do
        m    = ::Regexp.last_match
        name = m[2]

        if m[1] # a closing tag `</Name>`
          at = open_ats[name].last
          next unless at # stray close with no open → literal text, ignore

          raise_children_error(name, identifier, scan, at)
        elsif m[0].end_with?("/>") # self-closing → carries no children
          next
        else # an opening tag `<Name ...>` — record the NEAREST open of this name
          open_ats[name] << m.begin(0)
        end
      end

      nil
    end

    # Raise the self-contained {ChildrenNotSupportedError}. +at+ is the OPENING
    # tag's byte offset in +scan+ (position-faithful to the raw source), so the
    # line uses the same idiom as Step 2. Message mirrors
    # {ComponentContract.raise_error} so both loud preprocess errors read alike.
    def raise_children_error(component, identifier, scan, at)
      line     = scan[0...at].count("\n") + 1
      location = [identifier, line].compact.join(":")
      location = "(unknown location)" if location.empty?
      raise ChildrenNotSupportedError,
            "ruact: <#{component}> at #{location} children are not supported " \
            "— pass content as a prop, e.g. `<#{component} content={...} />`."
    end

    # Blank out Suspense open/close tags (the one legitimate paired PascalCase
    # tag) while preserving EVERY newline and byte offset, so the loud-children
    # scan neither trips on `<Suspense>...</Suspense>` nor mis-reports a line when
    # a multi-line Suspense opening precedes the offending tag. Non-newline chars
    # → spaces (same length); newlines kept verbatim.
    def mask_suspense(source)
      source
        .gsub(SUSPENSE_OPEN_RE)  { |m| m.gsub(/[^\n]/, " ") }
        .gsub(SUSPENSE_CLOSE_RE) { |m| m.gsub(/[^\n]/, " ") }
    end

    # Blank ERB islands (position-faithful, see {mask_suspense}) so component
    # tags that appear only inside Ruby/ERB string or comment text are invisible
    # to the loud-children tag scan.
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

    # Parses the attributes string of a component tag into ordered
    # +[name, ruby_expr]+ pairs, e.g. [["postId", "@post.id"], ["count", "5"]].
    # Honors nested braces in values (via {#extract_braced_expr}). The names
    # feed the Story 13.5 contract check; the pairs render the props Hash.
    def parse_prop_pairs(attrs_string)
      return [] if attrs_string.empty?

      pairs = []
      remaining = attrs_string.dup

      while (m = PROP_RE.match(remaining))
        prop_name = m[1]
        # Find the matching closing brace, respecting nesting
        value_start = m.end(0)
        value_expr  = extract_braced_expr(remaining, value_start)
        pairs << [prop_name, value_expr]
        # Advance past this prop
        remaining = remaining[(value_start + value_expr.length + 1)..] # +1 for closing }
        break if remaining.nil?
      end

      pairs
    end

    # Given a string and a start position (just after the opening '{'),
    # returns the content up to the matching '}'.
    def extract_braced_expr(str, start)
      depth = 1
      i = start
      while i < str.length && depth.positive?
        case str[i]
        when "{" then depth += 1
        when "}" then depth -= 1
        end
        i += 1
      end
      raise PreprocessorError, "unclosed brace in prop expression" if depth.positive?

      str[start...(i - 1)]
    end
  end
end
