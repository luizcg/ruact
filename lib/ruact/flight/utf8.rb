# frozen_string_literal: true

module Ruact
  module Flight
    # Every string leaves the serializer as valid UTF-8. A `T` row is framed by
    # its byte length, and JSON (a model row, the inline page payload) refuses
    # invalid UTF-8: one record holding Latin-1 bytes made its page answer 500
    # for every viewer.
    module Utf8
      REPLACEMENT = "\uFFFD"

      # Binary-tagged text (`File.binread`, an HTTP body) is retagged; another
      # encoding is transcoded; bytes that are not text in that encoding become
      # U+FFFD, as a browser shows them.
      #
      # @param value [String]
      # @return [String] valid UTF-8 (the same object when it already was)
      def self.text(value)
        return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?

        text =
          begin
            if [Encoding::BINARY, Encoding::UTF_8].include?(value.encoding)
              value.dup.force_encoding(Encoding::UTF_8)
            else
              value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
            end
          rescue Encoding::ConverterNotFoundError
            # An encoding Ruby cannot convert from (UTF-7, say): its bytes.
            value.dup.force_encoding(Encoding::UTF_8)
          end
        text.valid_encoding? ? text : text.scrub(REPLACEMENT)
      end
    end
  end
end
