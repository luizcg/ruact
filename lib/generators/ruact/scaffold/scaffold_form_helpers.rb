# frozen_string_literal: true

module Ruact
  module Generators
    class ScaffoldGenerator < Rails::Generators::NamedBase
      # Story 10.3 — the shadcn Form's view-model helpers: which `@/components/ui/*`
      # primitives to import, the component's prop signature, and the `references`
      # → `<Select>` options sourcing (controller ivar → prop). Extracted into its
      # own module to keep {ScaffoldGenerator} within its class-length budget
      # (mirrors the 10.2 {ScaffoldAttribute} extraction). Mixed in below the
      # `no_tasks` boundary so these never register as Thor commands.
      module FormHelpers
        # The :input-family shadcn controls (all render an `<Input>`, varying only
        # by `type=`); extracted so the predicate's array literal isn't rebuilt on
        # every loop iteration.
        INPUT_SHADCN_CONTROLS = %i[input number date datetime].freeze

        # The `references` attributes — each renders a shadcn `<Select>` whose
        # options the controller loads (ivar → prop). Empty for a reference-free
        # model (the whole options path then stays inert).
        def reference_attributes
          scaffold_attributes.select(&:reference?)
        end

        # The eager-options cap (template-friendly accessor for the constant).
        def reference_options_limit
          ScaffoldGenerator::REFERENCE_OPTIONS_LIMIT
        end

        # Story 10.3 (AC6) — the controller expression loading a `references`
        # field's options as plain `{ "id" =>, "label" => }` row hashes (no
        # `as_json`; the view passes them straight through as a prop). Labels fall
        # back name → title → `to_s`. Capped at the threshold + 1 so the eager
        # `<Select>` never balloons (a > threshold parent set wants the documented
        # server-search combobox instead).
        def reference_options_expr(ref)
          label = "record.try(:name) || record.try(:title) || record.to_s"
          "#{ref.reference_class_name}.limit(#{reference_options_limit + 1})" \
            ".map { |record| { \"id\" => record.id, \"label\" => #{label} } }"
        end

        # --- shadcn Form import predicates ------------------------------------
        # Emit only the `@/components/ui/*` imports the model's controls use, so a
        # reference-free Form never imports `Select`, a textarea-free Form never
        # imports `Textarea`, etc.

        def form_uses_input?
          scaffold_attributes.any? { |attr| INPUT_SHADCN_CONTROLS.include?(attr.shadcn_control) }
        end

        def form_uses_textarea?
          scaffold_attributes.any? { |attr| attr.shadcn_control == :textarea }
        end

        def form_uses_switch?
          scaffold_attributes.any? { |attr| attr.shadcn_control == :switch }
        end

        def form_uses_select?
          reference_attributes.any?
        end

        # The Form component's destructured props — `initial` plus one options
        # prop per `references` field (`authorOptions = []`).
        def form_props_params
          ["initial = null"] + reference_attributes.map { |ref| "#{ref.options_prop} = []" }
        end

        # FR99 — the Form component's prop type (typed mode only).
        def form_props_type
          parts = ["initial?: #{class_name}Row | null"]
          parts += reference_attributes.map { |ref| "#{ref.options_prop}?: { id: number; label: string }[]" }
          "{ #{parts.join('; ')} }"
        end

        # FR100 — the `__ruactContract` props object. EVERY prop the view may pass
        # must be declared or the 13.5 call-site validator rejects it: `initial`
        # plus each `references` options prop the new/edit views hand the Form.
        # All optional (`new` omits `initial`; a reference-free Form omits options).
        def form_contract_props
          parts = ['initial: "optional"']
          parts += reference_attributes.map { |ref| %(#{ref.options_prop}: "optional") }
          "{ #{parts.join(', ')} }"
        end

        # The `<Input type>` for the :input-family controls (string→text,
        # number, date, datetime→datetime-local). The shadcn `<Input>` forwards
        # `type` to the native element, so the wire formats match for free.
        def html_input_type(attr)
          case attr.shadcn_control
          when :number then "number"
          when :date then "date"
          when :datetime then "datetime-local"
          else "text"
          end
        end
      end
    end
  end
end
