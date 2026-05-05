# frozen_string_literal: true

require "nokogiri"

module Ruact
  # Converts an HTML string (ERB output) into a ReactElement tree.
  #
  # Rules:
  # - HTML attributes → React equivalents (class→className, for→htmlFor, etc.)
  # - data-react-key="x" → becomes the React key on the element
  # - HTML comments matching __RSC_N__ tokens → replaced by client component refs
  # - Text nodes → plain Ruby strings
  # - Multiple root nodes → wrapped in a Fragment (array)
  # rubocop:disable Metrics/ClassLength
  class HtmlConverter
    # HTML attribute → React prop name mapping
    HTML_TO_REACT = {
      "class" => "className",
      "for" => "htmlFor",
      "tabindex" => "tabIndex",
      "readonly" => "readOnly",
      "maxlength" => "maxLength",
      "cellpadding" => "cellPadding",
      "cellspacing" => "cellSpacing",
      "rowspan" => "rowSpan",
      "colspan" => "colSpan",
      "crossorigin" => "crossOrigin",
      "autocomplete" => "autoComplete",
      "autofocus" => "autoFocus",
      "accesskey" => "accessKey",
      "contenteditable" => "contentEditable",
      "enctype" => "encType",
      "formaction" => "formAction",
      "novalidate" => "noValidate",
      "spellcheck" => "spellCheck"
    }.freeze

    # Tags whose `value` attribute maps to React's `defaultValue` (uncontrolled).
    DEFAULT_VALUE_TAGS = %w[textarea select].freeze

    # <input type=...> values for which `value` keeps its name in React (button-like inputs).
    INPUT_BUTTON_TYPES = %w[submit reset button image].freeze

    # Convert an HTML string into a ReactElement tree.
    # component_registry is an array of { token:, name:, ref: ClientReference, props: Hash }
    #
    # Raises +Ruact::HtmlConverterError+ if +html+ is not a +String+. The
    # validation runs before Nokogiri is invoked, so the caller's file:line
    # appears at the top of the backtrace rather than Nokogiri internals.
    def self.convert(html, component_registry = [])
      new(component_registry).convert(html)
    end

    def initialize(component_registry)
      @registry = component_registry
    end

    # Convert an HTML string into a ReactElement tree (instance form).
    #
    # Raises +Ruact::HtmlConverterError+ if +html+ is not a +String+. The
    # validation runs before Nokogiri is invoked, so the caller's file:line
    # appears at the top of the backtrace rather than Nokogiri internals.
    def convert(html)
      validate_html_input!(html)

      # Wrap in a fragment container so Nokogiri gives us a consistent root.
      # Use HTML4 fragment parser (universally available, no libgumbo needed).
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      children = doc.children.reject { |n| ignorable?(n) }.filter_map { |n| convert_node(n) }

      case children.length
      when 0 then nil
      when 1 then children.first
      else        children # Fragment: array of elements
      end
    end

    private

    # Story 7.4: validate the +html+ input at the boundary so that a stray nil
    # or non-String value produces a clear ruact-named error pointing at the
    # caller's file:line instead of a Nokogiri stack trace.
    #
    # +String === html+ is used instead of +html.is_a?(String)+ because it
    # delegates to +Module#===+ on +String+ rather than calling a method on
    # +html+. This means even +BasicObject+ instances (which lack +is_a?+,
    # +kind_of?+, and +.class+) raise +Ruact::HtmlConverterError+ here instead
    # of +NoMethodError+. The message-building helper rescues every method
    # call on +html+ for the same reason.
    def validate_html_input!(html)
      return if String === html # rubocop:disable Style/CaseEquality

      # Walk the stack until we leave html_converter.rb — handles both the
      # class form (HtmlConverter.convert → instance #convert) and the
      # instance form, so the message always points at the application caller.
      gem_file = __FILE__
      stack = caller_locations(1, 10) || []
      app_frames = stack.drop_while { |loc| loc.path == gem_file }
      location = app_frames.first || stack.first

      message = build_input_error_message(html, location)
      app_backtrace = app_frames.map { |loc| "#{loc.path}:#{loc.lineno}:in `#{loc.label}'" }
      app_backtrace = caller(1) if app_backtrace.empty?
      raise Ruact::HtmlConverterError, message, app_backtrace
    end

    def build_input_error_message(value, location)
      called_from = "Called from: #{location.path}:#{location.lineno}"
      doc_pointer = "See HtmlConverter.convert documentation for the canonical contract."

      # +nil.equal?(value)+ instead of +value.nil?+: BasicObject has no
      # +nil?+ method, so identity comparison through nil's side is the
      # only safe path.
      if nil.equal?(value)
        <<~MSG.strip
          ruact: HtmlConverter.convert received nil; expected a String of HTML.
            Most likely cause: an ERB template, partial, or render path returned nil instead of an HTML string. Check the call site for a missing yield, an empty respond_to branch, or a partial that returned nil.
            #{called_from}
            #{doc_pointer}
        MSG
      else
        klass_name = safe_class_name(value)
        preview = safe_inspect_preview(value)
        <<~MSG.strip
          ruact: HtmlConverter.convert expected a String of HTML; got #{klass_name}.
            Received: #{preview}
            #{called_from}
            #{doc_pointer}
        MSG
      end
    end

    # Rescue around +.class+ so +BasicObject+ instances (and anything else
    # that overrides or lacks +.class+) still produce a readable message.
    def safe_class_name(value)
      value.class.to_s
    rescue StandardError
      "an unknown object"
    end

    # Truncate +inspect+ to 80 chars (preview window). Rescue any exception
    # raised by a hostile +inspect+ so the validation never propagates a
    # third-party error class instead of +Ruact::HtmlConverterError+.
    def safe_inspect_preview(value)
      raw = value.inspect
      raw = raw.to_s
      truncated = raw[0, 80]
      truncated += "..." if raw.length > 80
      truncated
    rescue StandardError
      "<inspect raised>"
    end

    def ignorable?(node)
      node.text? && node.text.strip.empty?
    end

    def convert_node(node)
      case node.type
      when Nokogiri::XML::Node::TEXT_NODE
        text = node.text
        text.strip.empty? ? nil : text

      when Nokogiri::XML::Node::COMMENT_NODE
        # Check if this is an RSC component placeholder
        token = node.content.strip
        entry = @registry.find { |c| c[:token] == token }
        return nil unless entry

        Flight::ReactElement.new(
          type: entry[:ref],
          key: nil,
          props: entry[:props]
        )

      when Nokogiri::XML::Node::ELEMENT_NODE
        convert_element(node)

      end
    end

    def convert_element(node)
      tag = node.name.downcase
      return convert_suspense_element(node) if tag == "rsc-suspense"

      props = build_props(node, tag)
      children = convert_children(node)
      props["children"] = children.length == 1 ? children.first : children unless children.empty?

      Flight::ReactElement.new(type: tag, key: node["data-react-key"], props: props)
    end

    def convert_suspense_element(node)
      fallback_text = node["data-rsc-fallback"] || ""
      fallback = if fallback_text.empty?
                   nil
                 else
                   Flight::ReactElement.new(type: "p", key: nil, props: { "children" => fallback_text })
                 end

      child_nodes = convert_children(node)
      children = child_nodes.length == 1 ? child_nodes.first : child_nodes

      Flight::SuspenseElement.new(fallback: fallback, children: children)
    end

    def convert_children(node)
      node.children.reject { |n| ignorable?(n) }.filter_map { |n| convert_node(n) }
    end

    def build_props(node, tag)
      props = {}
      node.attributes.each do |attr_name, attr_node|
        next if attr_name == "data-react-key"

        react_name = react_attr_name(attr_name, tag, node)
        props[react_name] = attr_name == "style" ? parse_style(attr_node.value) : attr_node.value
      end
      props
    end

    def react_attr_name(attr_name, tag, node)
      return "defaultValue" if attr_name == "value" && DEFAULT_VALUE_TAGS.include?(tag)
      return input_value_name(node) if attr_name == "value" && tag == "input"
      return "defaultChecked" if attr_name == "checked" && tag == "input"

      HTML_TO_REACT[attr_name] || camel_case_data(attr_name)
    end

    def input_value_name(node)
      input_type = node["type"]&.downcase
      INPUT_BUTTON_TYPES.include?(input_type) ? "value" : "defaultValue"
    end

    # Converts a CSS inline style string into a React-compatible hash with camelCase keys.
    # e.g. "font-size:16px;color:red" → {"fontSize" => "16px", "color" => "red"}
    def parse_style(css_string)
      css_string.split(";").each_with_object({}) do |decl, hash|
        prop, _, value = decl.partition(":")
        prop  = prop.strip
        value = value.strip
        next if prop.empty? || value.empty?

        camel = prop.split("-").each_with_index.map { |part, i| i.zero? ? part : part.capitalize }.join
        hash[camel] = value
      end
    end

    # data-foo-bar → "data-foo-bar" (kept as-is; React accepts kebab data attrs)
    # other kebab attrs not in the map → camelCase
    def camel_case_data(name)
      return name if name.start_with?("data-", "aria-")

      parts = name.split("-")
      parts.first + parts[1..].map(&:capitalize).join
    end
  end
  # rubocop:enable Metrics/ClassLength
end
