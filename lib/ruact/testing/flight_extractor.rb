# frozen_string_literal: true

module Ruact
  module Testing
    # Raised by {FlightExtractor.extract} when the given response/String is not
    # a Flight page render — most importantly when it is a plain-JSON
    # function-call/query response. The message tells the spec author what they
    # were handed and how to assert on it instead. Public: hosts may rescue it.
    class NotAFlightResponseError < StandardError; end

    # Pulls the Flight wire byte string out of whatever a host request spec
    # hands the `have_ruact_component` matcher: an ActionDispatch/Rack response
    # object (read via `.body`) or a raw String, in either of the two page
    # shapes ruact emits —
    #
    #   1. a raw `text/x-component` body (RSC/navigation request), OR
    #   2. a full HTML document embedding the payload in the `__FLIGHT_DATA`
    #      bootstrap `<script>` (a plain browser GET).
    #
    # A `Ruact::Server` function-call/query answer is plain JSON, not Flight —
    # feeding it here raises {NotAFlightResponseError} pointing at `JSON.parse`,
    # rather than silently failing to parse. Pure: no I/O, no global state.
    module FlightExtractor
      # Matches the `d.push("<ruby-inspected literal>")` line the
      # `__FLIGHT_DATA` bootstrap script emits (see
      # `Ruact::ViewHelper#ruact_flight_data_script`). The captured group is the
      # full double-quoted Ruby string literal (quotes included), honoring
      # escaped quotes so a `\"` inside the payload does not end the match.
      FLIGHT_DATA_PUSH = /\.push\((?<literal>"(?:\\.|[^"\\])*")\);/m

      # A Flight wire body always starts with a row header: `<hex>:` (id + colon)
      # or a hint row `:H`. JSON bodies start with `{`/`[`/`"`; HTML with `<`.
      FLIGHT_ROW_START = /\A\s*(?:\h+:|:H)/

      # Reverses `String#inspect` on the captured `__FLIGHT_DATA` literal.
      # `JSON.parse` is unsafe here: Ruby's inspect escapes sequences JSON
      # rejects (`\#` before `{`/`$`/`@`, `\e`, `\a`, …). These are the common
      # single-char escapes; an unrecognized `\c` yields the literal `c`.
      SIMPLE_ESCAPES = {
        "n" => "\n", "t" => "\t", "r" => "\r", "s" => " ", "0" => "\0",
        "a" => "\a", "b" => "\b", "e" => "\e", "f" => "\f", "v" => "\v",
        '"' => '"', "\\" => "\\"
      }.freeze

      class << self
        # @param response_or_string [#body, String] a response object or a raw
        #   body String.
        # @return [String] the extracted Flight wire byte string.
        # @raise [NotAFlightResponseError] when the input is a JSON function-call
        #   response, an empty body, or otherwise not a Flight page render.
        def extract(response_or_string)
          body, content_type = read(response_or_string)
          return extract_by_content_type(body, content_type) if content_type

          extract_by_sniffing(body)
        end

        private

        # Reads `[body, content_type]` from a response object or String. A bare
        # String has no content type; a response object may expose one via
        # `content_type`/`media_type` (rack-test, ActionDispatch) — read
        # defensively so any duck-typed `.body` object still works.
        def read(response_or_string)
          return [response_or_string, nil] if response_or_string.is_a?(String)

          unless response_or_string.respond_to?(:body)
            raise NotAFlightResponseError,
                  "have_ruact_component expects a response object (responds to #body) or a String, " \
                  "got #{response_or_string.class}."
          end

          [response_or_string.body.to_s, content_type_of(response_or_string)]
        end

        def content_type_of(response)
          %i[media_type content_type].each do |m|
            next unless response.respond_to?(m)

            value = response.public_send(m)
            return value.to_s.split(";").first&.strip unless value.nil? || value.to_s.empty?
          end
          nil
        rescue StandardError
          nil
        end

        def extract_by_content_type(body, content_type)
          case content_type
          when "text/x-component"
            ensure_present!(body)
            body
          when "text/html", "application/xhtml+xml"
            from_html(body)
          when "application/json"
            raise_json_error(body)
          else
            # Unknown content type — fall back to sniffing the bytes.
            extract_by_sniffing(body)
          end
        end

        def extract_by_sniffing(body)
          ensure_present!(body)

          return from_html(body) if body.include?("__FLIGHT_DATA")
          return body if body.match?(FLIGHT_ROW_START)
          # An HTML document that rendered no component reaches `from_html`,
          # which raises the actionable "no `__FLIGHT_DATA` payload" error.
          return from_html(body) if html_body?(body)

          raise_json_error(body) if json_body?(body)

          raise NotAFlightResponseError,
                "have_ruact_component could not find a Flight payload in the response. " \
                "The body is neither a raw `text/x-component` Flight body nor an HTML shell " \
                "embedding `__FLIGHT_DATA`. First bytes: #{body[0, 80].inspect}"
        end

        def from_html(html)
          match = html.match(FLIGHT_DATA_PUSH)
          unless match
            raise NotAFlightResponseError,
                  "have_ruact_component received an HTML document with no `__FLIGHT_DATA` payload. " \
                  "This response did not render a ruact component (no Flight data was inlined)."
          end

          decode_ruby_string_literal(match[:literal])
        end

        def json_body?(body)
          stripped = body.lstrip
          stripped.start_with?("{", "[", "\"")
        end

        def html_body?(body)
          stripped = body.lstrip
          stripped.start_with?("<") && /<(?:!doctype\b|html\b|body\b|div\b|head\b)/i.match?(stripped)
        end

        def raise_json_error(body)
          raise NotAFlightResponseError,
                "have_ruact_component received a plain-JSON response, not a Flight page. " \
                "`Ruact::Server` function-call and query responses answer JSON — assert on them with " \
                "`JSON.parse(response.body)` and a status check, not `have_ruact_component`. " \
                "First bytes: #{body[0, 80].inspect}"
        end

        def ensure_present!(body)
          return unless body.nil? || body.empty?

          raise NotAFlightResponseError,
                "have_ruact_component received an empty response body — nothing was rendered. " \
                "(A 204/no-content function-call response has no Flight payload.)"
        end

        def decode_ruby_string_literal(literal)
          inner = literal[1..-2] # strip surrounding quotes
          out = +""
          pos = 0
          len = inner.length
          while pos < len
            ch = inner[pos]
            if ch == "\\" && pos + 1 < len
              decoded, consumed = decode_escape(inner, pos + 1)
              out << decoded
              pos += 1 + consumed
            else
              out << ch
              pos += 1
            end
          end
          out
        end

        # Decodes the escape sequence that begins at `inner[pos]` (the char right
        # after the backslash). Returns `[decoded_string, input_chars_consumed]`
        # where `input_chars_consumed` counts only the chars AFTER the
        # backslash, so the caller can advance its cursor precisely.
        def decode_escape(inner, pos)
          ch = inner[pos]
          case ch
          when "u" then decode_unicode(inner, pos)
          when "x" then decode_hex(inner, pos)
          else
            [SIMPLE_ESCAPES.fetch(ch, ch), 1]
          end
        end

        # `\u{XXXX}` (braced, possibly multiple code points) or `\uXXXX`.
        def decode_unicode(inner, pos)
          if inner[pos + 1] == "{"
            close = inner.index("}", pos + 2) || (return ["u", 1])
            hex = inner[(pos + 2)...close]
            decoded = hex.split.map { |cp| cp.to_i(16) }.pack("U*")
            [decoded, (close - pos) + 1]
          else
            hex = inner[(pos + 1), 4].to_s
            [[hex.to_i(16)].pack("U"), 1 + hex.length]
          end
        end

        # `\xHH` (one or two hex digits).
        def decode_hex(inner, pos)
          hex = inner[(pos + 1)..].to_s[/\A\h{1,2}/].to_s
          return ["x", 1] if hex.empty?

          [[hex.to_i(16)].pack("C").force_encoding(inner.encoding), 1 + hex.length]
        end
      end
    end
  end
end
