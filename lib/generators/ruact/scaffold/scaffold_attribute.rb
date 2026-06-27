# frozen_string_literal: true

require "rails/generators/named_base"

module Ruact
  module Generators
    class ScaffoldGenerator < Rails::Generators::NamedBase
      # A single scaffold attribute (name + AR type) with the view-model helpers
      # the templates consume. `references` columns address `<name>_id`. Lives in
      # its own file to keep {ScaffoldGenerator} within its class-length budget;
      # reopens the generator class so `TYPE_MAP` resolves by lexical scope.
      class ScaffoldAttribute
        attr_reader :name, :type

        def initialize(name, type)
          @name = name
          @type = type
        end

        # The wire/DB column the controller params + serialized rows use.
        def column_name
          reference? ? "#{name}_id" : name
        end

        def ts_type
          TYPE_MAP.fetch(type)[:ts]
        end

        def control
          TYPE_MAP.fetch(type)[:control]
        end

        def boolean?
          type == "boolean"
        end

        # The DataTable cell renderer kind (Story 10.2 AC1):
        #   :badge   → boolean                          → Badge "Yes"/"No"
        #   :numeric → integer/float/decimal/references → right-aligned numeric
        #   :date    → date/datetime                    → locale-formatted
        #   :text    → string/text                      → plain text
        def column_kind
          case type
          when "boolean" then :badge
          when "integer", "float", "decimal", "references" then :numeric
          when "date", "datetime" then :date
          else :text
          end
        end

        def reference?
          type == "references"
        end

        # camelCase JS identifier for the column (`author_id` → `authorId`).
        def js_var
          parts = column_name.split("_")
          (parts.first(1) + parts.drop(1).map(&:capitalize)).join
        end

        # The React `useState` setter name (`authorId` → `setAuthorId`).
        def js_setter
          "set#{js_var.sub(/\A./, &:upcase)}"
        end
      end
    end
  end
end
