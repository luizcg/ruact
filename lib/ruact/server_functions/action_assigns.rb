# frozen_string_literal: true

module Ruact
  module ServerFunctions
    # What a server function's JSON is made of (decision, 2026-10-03): the
    # ivars the ACTION assigned, not everything a view would see.
    #
    # Two filters. Callbacks run before `send_action`, so what they put on the
    # controller (a `set_post`, a `set_current_user`) is recorded there and
    # left out of the JSON unless the action assigns it again. And some ivars
    # are filled DURING the action without the action naming them — Devise's
    # `current_user` memoizes `@current_user` on first call, Pundit's
    # `authorize` sets `@pundit` — so names in
    # `Ruact.config.server_function_hidden_ivars`, and every name starting
    # with `_`, are never returned. Without these, a function call carried the
    # signed-in user, and under `strict_serialization` (production's default)
    # a user model without `ruact_props` made every call a 500. A page
    # render's view still sees every ivar; only the function-call JSON
    # narrows.
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

      # +assigns+ minus what callbacks set and the action left holding the
      # same object. Only a DIFFERENT object makes it the action's: setting
      # the same value again (`@ok = false` after a callback did, a memoized
      # helper returning what the callback already stored) leaves it out.
      # Security first — a callback's `@current_user_id = 5` must not ride
      # every response — at the price of a key that is absent when callback
      # and action happen to agree.
      def __ruact_action_assigns(assigns)
        before = @__ruact_callback_ivars || {}
        hidden = Ruact.config.server_function_hidden_ivars
        assigns.reject do |name, value|
          name == CALLBACK_IVARS_KEY || name.start_with?("_") || hidden.include?(name) ||
            (before.key?(name) && before[name].equal?(value))
        end
      end
    end
  end
end
