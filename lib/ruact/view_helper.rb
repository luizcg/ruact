# frozen_string_literal: true

module Ruact
  # ActionView helper module included in ActionView::Base via Railtie.
  # Provides the +__rsc_component__+ method that ERB templates call after the
  # preprocessor transforms PascalCase tags into +<%= __rsc_component__(...) %>+.
  #
  # Thread-safe: ActionView creates a fresh view context per request, so there
  # is no shared state between concurrent requests.
  module ViewHelper
    # Registers +name+ with +props+ in the per-request ComponentRegistry and
    # returns an HTML comment placeholder that HtmlConverter later replaces with
    # a ReactElement node.
    #
    # The returned string MUST be html_safe so ActionView does not escape the
    # angle brackets — if it were escaped, HtmlConverter would not find the
    # placeholder in the HTML output.
    def __rsc_component__(name, props = {})
      token = ComponentRegistry.register(name, props)
      "<!-- #{token} -->".html_safe
    end
  end
end
