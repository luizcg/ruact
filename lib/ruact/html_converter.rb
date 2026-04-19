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

      # Special element: <rsc-suspense> → SuspenseElement (Suspense boundary)
      if tag == "rsc-suspense"
        fallback_text = node["data-rsc-fallback"] || ""
        fallback = if fallback_text.empty?
                     nil
                   else
                     Flight::ReactElement.new(type: "p", key: nil, props: { "children" => fallback_text })
                   end

        child_nodes = node.children.reject { |n| ignorable?(n) }.filter_map { |n| convert_node(n) }
        children = child_nodes.length == 1 ? child_nodes.first : child_nodes

        return Flight::SuspenseElement.new(fallback: fallback, children: children)
      end

      key = node["data-react-key"]
      props = {}

      node.attributes.each do |attr_name, attr_node|
        next if attr_name == "data-react-key"

        react_name = if attr_name == "value" && %w[textarea select].include?(tag)
                       "defaultValue"
                     elsif attr_name == "value" && tag == "input"
                       input_type = node["type"]&.downcase
                       %w[submit reset button image].include?(input_type) ? "value" : "defaultValue"
                     elsif attr_name == "checked" && tag == "input"
                       "defaultChecked"
                     else
                       HTML_TO_REACT[attr_name] || camel_case_data(attr_name)
                     end
        props[react_name] = attr_name == "style" ? parse_style(attr_node.value) : attr_node.value
      end

      children = node.children.reject { |n| ignorable?(n) }.filter_map { |n| convert_node(n) }

      unless children.empty?
        props["children"] = children.length == 1 ? children.first : children
      end

      Flight::ReactElement.new(type: tag, key: key, props: props)
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
