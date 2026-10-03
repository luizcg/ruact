# frozen_string_literal: true

module Ruact
  # Reducing a same-origin redirect URL to its path is what lets the client
  # navigate in place. One path must not be produced that way: `//host` (or
  # `/\host`), which a browser reads as a URL to ANOTHER host. Shared by the
  # page redirect ({Ruact::Controller}) and the server-function `$redirect`
  # ({Ruact::Server}); neither loads the other.
  module RedirectPath
    # @param path [String] a redirect target already reduced to a path
    # @return [Boolean] whether a browser would read it as another host
    def self.protocol_relative?(path)
      path.match?(%r{\A[/\\]{2}})
    end
  end
end
