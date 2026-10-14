# frozen_string_literal: true

require "json"

module Ruact
  # Internal — data written inside an inline `<script>` element.
  #
  # The Flight payload carries application data (props, record content), so it
  # is embedded as a JSON string literal with `<`, `>`, `&`, U+2028 and U+2029
  # escaped as `\uXXXX`. No byte of the payload can then close the `<script>` —
  # `</SCRIPT>`, `</script >` and `<!--` included — and every character reaches
  # JavaScript intact.
  module InlineScript
    UNSAFE = /[<>&  ]/

    # A JSON string literal for +string+ that is safe inside a `<script>`.
    # The payload is UTF-8 by construction (the serializer normalizes every
    # string); a binary-tagged buffer is retagged, not transcoded.
    def self.string_literal(string)
      utf8 = string.encoding == Encoding::UTF_8 ? string : string.dup.force_encoding(Encoding::UTF_8)
      JSON.generate(utf8).gsub(UNSAFE) { |char| format("\\u%04x", char.ord) }
    end
  end
end
