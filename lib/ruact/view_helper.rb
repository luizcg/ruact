# frozen_string_literal: true

module Ruact
  # ActionView helper module included in ActionView::Base via Railtie.
  # Provides the +__rsc_component__+ method that ERB templates call after the
  # preprocessor transforms PascalCase tags into +<%= __rsc_component__(...) %>+.
  #
  # Thread-safe: ActionView creates a fresh view context per request, so the
  # render context (set by Ruact::Controller#rsc_render before render_to_string)
  # is per-request — no shared state.
  module ViewHelper
    # Registers +name+ with +props+ in the per-render RenderContext (set by
    # Ruact::Controller#rsc_render on the view context as +@__ruact_render_context__+)
    # and returns an HTML comment placeholder that HtmlConverter later replaces
    # with a ReactElement node.
    #
    # The returned string MUST be html_safe so ActionView does not escape the
    # angle brackets — if it were escaped, HtmlConverter would not find the
    # placeholder in the HTML output.
    def __rsc_component__(name, props = {})
      ctx = @__ruact_render_context__
      raise Ruact::Error, "ruact: __rsc_component__ called outside an rsc_render flow" if ctx.nil?

      token = ctx.register(name, props)
      "<!-- #{token} -->".html_safe
    end
  end
end
