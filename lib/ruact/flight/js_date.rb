# frozen_string_literal: true

module Ruact
  module Flight
    # The ISO 8601 form a JavaScript `Date` reads back (Story 17-0c).
    module JsDate
      # JavaScript parses years 0–9999 in the plain form and the others only in
      # the expanded one (`+010000`, `-000001`); Ruby writes `10000` / `-0001`,
      # which `new Date` turns into an Invalid Date.
      #
      # @param value [Time, DateTime]
      # @return [String] ISO 8601 with milliseconds
      def self.iso8601(value)
        iso = value.iso8601(3)
        year = value.year
        return iso unless year.negative? || year > 9999

        format("%<sign>s%<year>06d", sign: year.negative? ? "-" : "+", year: year.abs) + iso.sub(/\A-?\d+/, "")
      end
    end
  end
end
