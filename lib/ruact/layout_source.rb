# frozen_string_literal: true

module Ruact
  # Answers one question in ONE place: does this layout actually wire ruact up?
  #
  # Two callers need that answer and must not disagree about it — the runtime
  # (`Ruact::Controller::DocumentRendering`, deciding whether it is safe to
  # render through the host layout) and `ruact:install` (deciding whether the
  # layout still needs migrating). When they each carried their own notion of
  # "present", they drifted: the generator skipped a layout as already-migrated
  # on a `<%# TODO: add ruact_js_assets %>` comment, while the runtime read the
  # same layout as unwired. Both were string-matching a NAME where only a CALL
  # counts.
  module LayoutSource
    # ERB comments are stripped before anything else. A commented-out call —
    # `<%# <%= ruact_js_assets %> %>`, which a developer produces the moment
    # they disable it while debugging — emits NOTHING, so counting it as wired
    # would report a layout as migrated when it is not. The `-?` covers ERB's
    # trim-mode forms (`<%-#` / `-%>`), which Erubi treats as comments too and
    # an earlier version of this pattern missed.
    ERB_COMMENT = /<%-?#.*?-?%>/m

    # An ERB OUTPUT tag calling the helper: `<%= ruact_js_assets %>` and the raw
    # `<%== ... %>` form, with or without arguments or surrounding whitespace.
    # Scanning stops at the tag's own `%>` rather than forbidding `%` outright —
    # `<%= raw("100%") + ruact_js_assets %>` is a legitimate call that a
    # `[^%]*` pattern rejected, while still never matching a bare mention that
    # merely follows some other tag.
    ASSETS_CALL = /<%=+(?:(?!%>).)*?\bruact_js_assets\b/m

    # The React mount target, as an attribute rather than as a substring. The
    # lookbehind is what stops `data-id="root"` (and any other `*-id`) from
    # counting: those are not the mount point, and a document that has one but
    # no real root gives React nothing to mount into. Unquoted `id=root` is
    # valid HTML and is accepted.
    ROOT_ATTRIBUTE = /(?<![-\w])id\s*=\s*(?:"root"|'root'|root(?=[\s>]))/

    # The whole element, for a generator that needs something to inject AFTER.
    ROOT_ELEMENT = %r{<div\s[^>]*#{ROOT_ATTRIBUTE.source}[^>]*>\s*</div>}

    class << self
      # Does this ERB source actually CALL `ruact_js_assets`?
      def wired?(source)
        without_comments(source).match?(ASSETS_CALL)
      end

      # Does this markup carry a React mount target? Used on RENDERED HTML by
      # the runtime and on ERB source by the generator; the attribute shape is
      # the same either way.
      def root?(markup)
        markup.to_s.match?(ROOT_ATTRIBUTE)
      end

      def without_comments(source)
        source.to_s.gsub(ERB_COMMENT, "")
      end
    end
  end
end
