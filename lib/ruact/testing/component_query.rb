# frozen_string_literal: true

require_relative "flight_wire_parser"

module Ruact
  module Testing
    # Resolves "was component <name> rendered, and with what props?" out of a
    # decoded Flight tree. Pure — no RSpec, no I/O. The public
    # `have_ruact_component` matcher is a thin RSpec wrapper over this.
    #
    # A component is TWO wire rows (Story 7.5 / FR108 semantics):
    #
    #   * an `:import` row — `["<module path>", "<export name>", [chunks…]]` —
    #     sourced from the client manifest (`reference_for`); its `:id` is the
    #     integer the model rows reference; AND
    #   * one or more `:model` rows carrying a React element
    #     `["$", "$L<hex id>", key, {props}]` whose type references that import.
    #
    # `have_ruact_component("PostList")` matches the import row's DECLARED name
    # (D3): its export name OR its module basename (`/PostList.jsx` → `PostList`)
    # — honest to what the wire actually contains, not the ERB tag or a mapping
    # the wire does not carry. Props are read from the model element's 4th slot
    # in their SERIALIZED wire form (D4: string keys, serialized values).
    class ComponentQuery
      # A React element on the wire is a 4-tuple whose head is the sentinel "$".
      ELEMENT_HEAD = "$"
      # A client-component element's type is "$L" followed by the import's hex id.
      CLIENT_REF = /\A\$L(?<hex>\h+)\z/

      # @param wire [String] the raw Flight wire byte string.
      def initialize(wire)
        @rows = FlightWireParser.parse(wire)
        @imports = index_imports(@rows)
        @instances = collect_instances(@rows)
      end

      # @return [Boolean] whether any instance of `name` was rendered.
      def rendered?(name)
        !props_for(name).empty?
      end

      # @return [Array<Hash>] the serialized props hash of every rendered
      #   instance of `name`, in wire order. Empty when `name` was not rendered.
      def props_for(name)
        ids = import_ids_for(name)
        return [] if ids.empty?

        @instances.select { |inst| ids.include?(inst[:ref_id]) }.map { |inst| inst[:props] }
      end

      # @return [Array<String>] every distinct component name present in the
      #   wire (by declared export name), for a legible failure message.
      def rendered_names
        rendered_ids = @instances.map { |inst| inst[:ref_id] }.uniq
        @imports.slice(*rendered_ids).map { |_, meta| meta[:export_name] }.uniq
      end

      private

      def index_imports(rows)
        rows.each_with_object({}) do |row, acc|
          next unless row[:class] == :import

          payload = row[:payload]
          next unless payload.is_a?(Array)

          module_path = payload[0]
          export_name = payload[1]
          acc[row[:id]] = {
            module_path: module_path,
            export_name: export_name,
            basename: module_path.is_a?(String) ? File.basename(module_path, ".*") : nil
          }
        end
      end

      def import_ids_for(name)
        @imports.select do |_id, meta|
          meta[:export_name] == name || meta[:basename] == name
        end.keys
      end

      # Walk every model row's payload, collecting each client-component element
      # `["$", "$L<hex>", key, props]` as `{ ref_id:, props: }`.
      def collect_instances(rows)
        instances = []
        rows.each do |row|
          next unless row[:class] == :model

          walk(row[:payload], instances)
        end
        instances
      end

      def walk(node, instances)
        if element?(node)
          ref = node[1].match(CLIENT_REF)
          instances << { ref_id: ref[:hex].to_i(16), props: node[3] } if ref
          # An element's props/children may themselves contain nested elements.
          walk(node[3], instances)
        elsif node.is_a?(Array)
          node.each { |child| walk(child, instances) }
        elsif node.is_a?(Hash)
          node.each_value { |child| walk(child, instances) }
        end
      end

      def element?(node)
        node.is_a?(Array) && node.length >= 4 && node[0] == ELEMENT_HEAD && node[1].is_a?(String)
      end
    end
  end
end
