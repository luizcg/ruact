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
  #   <%= __rsc_component__("LikeButton", { "postId" => @post.id, "initialCount" => 5 }) %>
  #
  # The placeholder is replaced by an HTML comment with a unique token:
  #   <!-- __RSC_COMPONENT_0__ -->
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

    # Matches a +{ruby_expr}+ attribute value — captures everything between the braces.
    # We use a simple bracket-depth counter approach during scanning instead of regex
    # because expressions can contain nested braces: {foo.bar({ a: 1 })}.
    PROP_RE = /\b([a-zA-Z_][a-zA-Z0-9_]*)=\{/

    # Transform ERB source, replacing component tags with ERB placeholders.
    # Returns the transformed source string.
    def self.transform(source)
      new.transform(source)
    end

    def transform(source)
      # Step 1: transform <Suspense> paired tags into <rsc-suspense> HTML elements.
      # This runs before the general component regex so Suspense isn't treated as a component.
      result = source
               .gsub(SUSPENSE_OPEN_RE) do
                 attrs    = ::Regexp.last_match(1)
                 fallback = extract_string_attr(attrs, "fallback") || ""
                 escaped  = fallback.gsub('"', "&quot;")
                 %(<rsc-suspense data-rsc-fallback="#{escaped}">)
               end
        .gsub(SUSPENSE_CLOSE_RE, "</rsc-suspense>")

      # Step 2: transform remaining PascalCase self-closing / opening component tags.
      result.gsub(COMPONENT_TAG_RE) do |match|
        component_name = ::Regexp.last_match(1)
        attrs_string   = ::Regexp.last_match(2).to_s.strip
        match_start    = ::Regexp.last_match.begin(0)
        line           = result[0...match_start].count("\n") + 1

        begin
          props_ruby = parse_props(attrs_string)
          props_hash = props_ruby.empty? ? "{}" : "{ #{props_ruby} }"
          %(<%= __rsc_component__(#{component_name.inspect}, #{props_hash}) %>)
        rescue PreprocessorError => e
          raise PreprocessorError, "#{e.message} at line #{line}: #{match.strip}"
        end
      end
    end

    private

    # Extract a string attribute value (double or single quoted) from an attrs string.
    def extract_string_attr(attrs, name)
      m = attrs.match(/\b#{Regexp.escape(name)}\s*=\s*"([^"]*)"/) ||
          attrs.match(/\b#{Regexp.escape(name)}\s*=\s*'([^']*)'/)
      m&.[](1)
    end

    # Parses the attributes string of a component tag and returns a Ruby
    # fragment representing a Hash literal, e.g.:
    #   "postId" => @post.id, "initialCount" => 5
    def parse_props(attrs_string)
      return "" if attrs_string.empty?

      pairs = []
      remaining = attrs_string.dup

      while (m = PROP_RE.match(remaining))
        prop_name = m[1]
        # Find the matching closing brace, respecting nesting
        value_start = m.end(0)
        value_expr  = extract_braced_expr(remaining, value_start)
        pairs << "#{prop_name.inspect} => #{value_expr}"
        # Advance past this prop
        remaining = remaining[(value_start + value_expr.length + 1)..] # +1 for closing }
        break if remaining.nil?
      end

      pairs.join(", ")
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
