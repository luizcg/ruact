# frozen_string_literal: true

module Ruact
  # Module prepended into ActionView::Template::Handlers::ERB via Railtie.
  # Applies the RSC preprocessor to every ERB template source before
  # ActionView compiles it — transparent to views, layouts, and partials.
  #
  # ErbPreprocessor.transform has a fast-path O(1) return when the source
  # contains no PascalCase tags, so non-RSC templates pay essentially no cost.
  #
  # Idempotent: prepend is a no-op if this module is already in the ancestor
  # chain, so reloads in development mode are safe.
  module ErbPreprocessorHook
    # Called by ActionView for every ERB template. +source+ is the raw ERB
    # text; the return value is Ruby code that ActionView will eval.
    def call(template, source)
      super(template, ErbPreprocessor.transform(source))
    end
  end
end
