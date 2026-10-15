# frozen_string_literal: true

module Ruact
  # Story 19-2 (AC10) — in development, `content_for`/`provide` inside a
  # `<Suspense>` that runs after the shell is an error of that block: the layout
  # was sent before the block ran, so nothing it declares shows. What the view
  # had declared is taken before the block and compared after.
  #
  # Internal API: not part of the public compatibility contract.
  module DeclaredContent
    # What +view+ has declared so far, or nil when it keeps no record.
    def self.take(view)
      return nil unless view.respond_to?(:view_flow) && view.view_flow.respond_to?(:content)

      view.view_flow.content.transform_values(&:to_s)
    end

    # Raises when +view+ declared more than +before+.
    def self.check!(view, before)
      after = view.view_flow.content
      changed = after.keys.reject { |name| name == :layout || after[name].to_s == before[name] }
      return if changed.empty?

      raise Ruact::Error,
            "#{changed.map { |name| "content_for :#{name}" }.join(', ')} inside a <Suspense> runs after the " \
            "layout was sent, so the layout never shows it. Move it outside the <Suspense>."
    end
  end
end
