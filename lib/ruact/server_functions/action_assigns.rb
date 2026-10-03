# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # What a server function's JSON is made of (decision, 2026-10-03): the
    # ivars the ACTION assigned, not everything a view would see.
    #
    # Callbacks run before `send_action`, so what they put on the controller —
    # an auth layer's memoized `@current_user` (Devise's `current_user` does
    # that), a `set_post` — is recorded there and left out of the JSON unless
    # the action assigns it again. Without this, every function call carried
    # the signed-in user, and under `strict_serialization` (production's
    # default) a non-Serializable user made every call a 500. The view of a
    # page render still sees every ivar; only the function-call JSON narrows.
    module ActionAssigns
      # The snapshot's own name, kept out of what it filters.
      CALLBACK_IVARS_KEY = "__ruact_callback_ivars"

      private

      def send_action(...)
        if __ruact_function_call?
          @__ruact_callback_ivars = instance_variables.to_h do |name|
            [name.to_s.delete_prefix("@"), instance_variable_get(name)]
          end
        end
        super
      end

      # +assigns+ minus what callbacks set and the action left as it was (the
      # same object). An ivar the action reassigned — even to an equal
      # object — is the action's.
      def __ruact_action_assigns(assigns)
        before = @__ruact_callback_ivars
        assigns = assigns.except(CALLBACK_IVARS_KEY)
        return assigns unless before

        assigns.reject { |name, value| before.key?(name) && before[name].equal?(value) }
      end
    end
  end
end
