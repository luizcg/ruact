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
    def self.convert(html, component_registry = [])
      new(component_registry).convert(html)
    end

    def initialize(component_registry)
      @registry = component_registry
    end

    def convert(html)
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
end
