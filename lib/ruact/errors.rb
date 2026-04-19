# frozen_string_literal: true

module Ruact
  class Error < StandardError; end

  # Raised when react-client-manifest.json is absent or a component is not found in it.
  class ManifestError < Error; end

  # Raised when a Ruby value cannot be serialized as a React prop.
  class SerializationError < Error; end

  # Raised when the ERB preprocessor encounters a malformed component tag.
  class PreprocessorError < Error; end
end
