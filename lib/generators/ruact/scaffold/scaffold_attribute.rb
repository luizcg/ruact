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

        # date/datetime — the List sorts these columns by epoch time (Story 10.2b).
        def date?
          column_kind == :date
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

        # The shadcn Form control this attribute renders as (Story 10.3 AC1):
        #   :input    → string                → <Input type="text">
        #   :textarea → text                  → <Textarea>
        #   :switch   → boolean               → <Switch>
        #   :number   → integer/float/decimal → <Input type="number">
        #   :date     → date                  → <Input type="date">
        #   :datetime → datetime              → <Input type="datetime-local">
        #   :select   → references            → <Select> of parent options
        # The :input/:number/:date/:datetime kinds all render an <Input>; the
        # concrete `type=` attribute comes from `html_input_type` (FormHelpers).
        def shadcn_control
          case type
          when "text" then :textarea
          when "boolean" then :switch
          when "integer", "float", "decimal" then :number
          when "date" then :date
          when "datetime" then :datetime
          when "references" then :select
          else :input
          end
        end

        # references only — the parent model constant (`author` → `Author`,
        # `blog_post` → `BlogPost`), used by the controller's options loader.
        def reference_class_name
          name.camelize
        end

        # references only — the controller ivar / view local holding the capped
        # parent options (`author` → `author_options`).
        def options_ivar
          "#{name}_options"
        end

        # references only — the camelCase prop the view passes and the Form reads
        # (`author` → `authorOptions`, `blog_post` → `blogPostOptions`).
        def options_prop
          parts = name.split("_")
          "#{(parts.first(1) + parts.drop(1).map(&:capitalize)).join}Options"
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
