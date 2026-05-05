# frozen_string_literal: true

module Ruact
  class Error < StandardError; end

  # Raised when react-client-manifest.json is absent or a component is not found in it.
  class ManifestError < Error; end

  # Raised when a Ruby value cannot be serialized as a React prop.
  class SerializationError < Error; end

  # Raised when the ERB preprocessor encounters a malformed component tag.
  class PreprocessorError < Error; end

  # Raised when application code attempts to mutate Ruact::Configuration outside
  # of a Ruact.configure block. The configuration is frozen after initialization
  # to prevent runtime drift; see Story 7.3 for the rationale and the decision
  # note for guidance on when re-configuration at runtime is appropriate.
  class ConfigurationError < Error; end

  # Raised by `Ruact::HtmlConverter.convert` when its input is not a `String`
  # (the only accepted shape). Catches the most common upstream bug — an ERB
  # template, partial, or render path that returned `nil` or a non-String value
  # — at the boundary, before Nokogiri is invoked, so the failing file:line and
  # the expected shape are visible at the top of the backtrace instead of
  # buried under a Nokogiri stack. See Story 7.4 for the rationale.
  class HtmlConverterError < Error; end
end
