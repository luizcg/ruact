# frozen_string_literal: true

module Ruact
  module ViewHelper
    # The helper a `<Suspense>` becomes ({ErbPreprocessor}). Part of
    # {ViewHelper}.
    module Suspense
      # A `<Suspense>`: the preprocessor makes the ERB between its tags this
      # block's body, and passes the `fallback` and `delay` attributes as the
      # template wrote them.
      #
      # In an action that streams (`ruact_streaming`), the block is kept, not
      # run: the marker ({Markers}) carries its index, and the response renders
      # it after the shell is sent ({DeferredRender}). Anywhere else the content
      # is evaluated here, in place, so the page renders as one piece — and, in
      # development, the log says the action could stream.
      #
      # Only what the block writes is the content: a value it ends on is not
      # (`capture` would print a block's value when it writes nothing).
      def __ruact_suspense__(fallback, delay = nil, &block)
        ctx = @ruact_render_context
        if ctx&.deferring?
          index = ctx.defer_block(RenderContext::Block.new(self, block, @virtual_path, @current_template,
                                                           caller_locations(1, 1).first))
          return "#{Markers.suspense_open(fallback, delay, block: index)}#{Markers::SUSPENSE_CLOSE}".html_safe
        end

        __ruact_note_unstreamed_suspense(ctx, caller_locations(1, 1).first) if ctx
        content = capture do
          yield
          nil
        end
        "#{Markers.suspense_open(fallback, delay)}#{content}#{Markers::SUSPENSE_CLOSE}".html_safe
      end

      # Story 19-1 — a `<Suspense>` in an action that does not stream renders its
      # content before the page is sent, as it always did. Development says so,
      # once per response, with the line that makes the action stream.
      def __ruact_note_unstreamed_suspense(ctx, location)
        return unless defined?(Rails) && Rails.env.development?
        return if ctx.unstreamed_suspense_noted?

        ctx.note_unstreamed_suspense!

        owner = respond_to?(:controller) ? controller : nil
        return unless owner.respond_to?(:action_name) && owner.respond_to?(:logger)
        # Declared, and answering a request it cannot stream to (HTTP/1.0).
        return if owner.class.respond_to?(:ruact_streaming?) && owner.class.ruact_streaming?(owner.action_name)

        where = location ? " (#{location.path.delete_prefix("#{Rails.root}/")}:#{location.lineno})" : ""
        owner.logger&.warn(
          "[ruact] #{owner.class.name}##{owner.action_name} renders a <Suspense>#{where} in an action " \
          "that does not stream, so its content ran before the page was sent. To send the page first " \
          "and the content when it is ready, add `ruact_streaming only: :#{owner.action_name}` to " \
          "#{owner.class.name}."
        )
      end

      private :__ruact_note_unstreamed_suspense
    end
  end
end
