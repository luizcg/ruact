# frozen_string_literal: true

module Ruact
  # The attributes of a PascalCase component tag in ERB, read the way JSX
  # reads them (see {ErbPreprocessor}). Returns ordered
  # +[name, ruby_expr]+ pairs for the props Hash the template renders.
  module ComponentAttributes
    ATTR_NAME_RE = /\A[a-zA-Z_][\w-]*/

    # Parses the attributes string of a component tag into ordered
    # +[name, ruby_expr]+ pairs, e.g. [["postId", "@post.id"], ["title", "\"Hi\""]].
    # The names feed the Story 13.5 contract check; the pairs render the props
    # Hash. The three JSX attribute forms:
    #
    #   name={ruby}   — the Ruby expression (nested braces honored)
    #   name="text"   — the string, as JSX passes it (single quotes too)
    #   name          — +true+, as JSX passes a bare attribute
    #
    # Anything else raises instead of being dropped: an unbraced attribute used
    # to vanish without a word, and it is the first thing a JSX hand writes.
    def self.parse(attrs_string)
      attrs = attrs_string.sub(%r{\s*/\z}, "")
      pairs = []
      i = 0
      while i < attrs.length
        if attrs[i].match?(/\s/)
          i += 1
          next
        end
        name = attrs[i..][ATTR_NAME_RE] ||
               raise(PreprocessorError, "unexpected #{attrs[i, 20].inspect} in the component's attributes")
        i += name.length
        i += 1 while attrs[i]&.match?(/\s/)
        if attrs[i] == "="
          i += 1
          i += 1 while attrs[i]&.match?(/\s/)
          value, i = parse_value(attrs, i, name)
          pairs << [name, value]
        else
          pairs << [name, "true"]
        end
      end
      pairs
    end

    # One attribute value at +attrs[i]+ → [ruby_expr, index after it].
    def self.parse_value(attrs, pos, name)
      case attrs[pos]
      when "{"
        expr = extract_braced_expr(attrs, pos + 1)
        [expr, pos + expr.length + 2]
      when '"', "'"
        close = attrs.index(attrs[pos], pos + 1)
        text = attrs[(pos + 1)...(close || attrs.length)]
        if text.include?("<%")
          raise PreprocessorError, "#{name}= holds ERB, which a component attribute cannot run. " \
                                   "Pass the Ruby in braces instead: #{name}={...}"
        end
        raise PreprocessorError, "unclosed quote in #{name}=" unless close

        [text.inspect, close + 1]
      else
        raise PreprocessorError, "#{name}= needs a value: #{name}={ruby} or #{name}=\"text\""
      end
    end

    # Given a string and a start position (just after the opening '{'),
    # returns the content up to the matching '}'.
    def self.extract_braced_expr(str, start)
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

    private_class_method :parse_value, :extract_braced_expr
  end
end
