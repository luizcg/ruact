# frozen_string_literal: true

module Ruact
  # ActionView helper module included in ActionView::Base via Railtie.
  # Provides the +__ruact_component__+ method that ERB templates call after the
  # preprocessor transforms PascalCase tags into +<%= __ruact_component__(...) %>+.
  #
  # Thread-safe: ActionView creates a fresh view context per request, so the
  # render context (set by Ruact::Controller#ruact_render on the controller as
  # +@ruact_render_context+ and copied to the view by Rails's view_assigns
  # plumbing — see Story 7.9 / Bug 7.8-B) is per-request — no shared state.
  module ViewHelper
    # Registers +name+ with +props+ in the per-render RenderContext (set by
    # Ruact::Controller#ruact_render on the controller as +@ruact_render_context+;
    # Rails copies it to the view via +_assigns_for_view_context+ because the
    # name does not match +DEFAULT_PROTECTED_INSTANCE_VARIABLES+'s +/\A@_/+
    # filter) and returns an HTML comment placeholder that HtmlConverter later
    # replaces with a ReactElement node.
    #
    # The returned string MUST be html_safe so ActionView does not escape the
    # angle brackets — if it were escaped, HtmlConverter would not find the
    # placeholder in the HTML output.
    def __ruact_component__(name, props = {})
      ctx = @ruact_render_context
      raise Ruact::Error, "ruact: __ruact_component__ called outside a ruact_render flow" if ctx.nil?

      token = ctx.register(name, props)
      "<!-- #{token} -->".html_safe
    end
  end
end
