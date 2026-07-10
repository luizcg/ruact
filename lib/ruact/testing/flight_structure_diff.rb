# frozen_string_literal: true

module Ruact
  module Testing
    # Pure structural diff + predicate-matching engine over parsed Flight rows
    # (see {FlightWireParser}). No RSpec dependency — the RSpec matcher DSL that
    # consumes it (the public `have_ruact_component` and the internal
    # `match_flight_structure`/`include_flight_row`) lives elsewhere. Promoted
    # from `spec/support` in Story 15.4 so the public helper and the internal
    # matchers share ONE implementation (wrap, not fork).
    # rubocop:disable Metrics/ClassLength -- single cohesive helper for matcher diffing/formatting; splitting would scatter related logic across files.
    class FlightStructureDiff
      # Keys the parser produces on every row. Predicates and expected rows
      # may only reference these keys; unknown keys raise upfront so typos
      # like `payloed:` don't silently match every row via `nil == nil`.
      KNOWN_ROW_KEYS = %i[id class payload raw].freeze

      # Keys that must be present in every expected-row hash passed to
      # `match_flight_structure`. Excludes `:raw` because expected rows are
      # authored as semantic descriptions, not byte-level snapshots.
      REQUIRED_EXPECTED_KEYS = %i[id class payload].freeze

      # Compute the set of differences between actual parsed rows and the
      # expected structure. Import rows are matched as a multiset (their
      # relative order among each other is not significant per AC1);
      # everything else compares positionally.
      def self.compute(actual_rows, expected_rows)
        validate_expected_rows!(expected_rows)
        return diffs_for_length_mismatch(actual_rows, expected_rows) if actual_rows.length != expected_rows.length

        diffs = []
        pending_actual_imports = []
        pending_expected_imports = []

        actual_rows.zip(expected_rows).each_with_index do |(actual, expected), i|
          if actual[:class] == :import && expected[:class] == :import
            pending_actual_imports << [i, actual]
            pending_expected_imports << [i, expected]
            next
          end

          next if rows_equal?(actual, expected)

          diffs << build_field_diff(i, actual, expected)
        end

        diffs.concat(diff_imports_unordered(pending_actual_imports, pending_expected_imports))
        diffs.sort_by { |d| d[:idx] }
      end

      # Imports are an unordered multiset within their class (AC1). Sort both
      # sides by `:id` (always unique per render) and any leftover diffs come
      # from semantic mismatch in the same-position-after-sort pair.
      def self.diff_imports_unordered(actual_pairs, expected_pairs)
        return [] if actual_pairs.empty? && expected_pairs.empty?

        sort_key = ->(pair) { [pair[1][:id].to_i, pair[1][:payload].to_s] }
        sorted_actual = actual_pairs.sort_by(&sort_key)
        sorted_expected = expected_pairs.sort_by(&sort_key)

        sorted_actual.zip(sorted_expected).filter_map do |(act_idx, act_row), (_exp_idx, exp_row)|
          next if rows_equal?(act_row, exp_row)

          build_field_diff(act_idx, act_row, exp_row)
        end
      end

      def self.diffs_for_length_mismatch(actual_rows, expected_rows)
        diffs = []
        [actual_rows.length, expected_rows.length].max.times do |i|
          actual = actual_rows[i]
          expected = expected_rows[i]
          if actual.nil?
            diffs << { kind: :missing, idx: i, expected_row: expected }
          elsif expected.nil?
            diffs << { kind: :extra, idx: i, actual_row: actual }
          elsif !rows_equal?(actual, expected)
            diffs << build_field_diff(i, actual, expected)
          end
        end
        diffs
      end

      def self.rows_equal?(actual, expected)
        REQUIRED_EXPECTED_KEYS.all? { |k| actual[k] == expected[k] }
      end

      def self.build_field_diff(idx, actual, expected)
        field_diff = nil
        REQUIRED_EXPECTED_KEYS.each do |key|
          next if actual[key] == expected[key]

          path, sub_expected, sub_actual = first_difference(expected[key], actual[key], ".#{key}")
          field_diff = { path: path, expected: sub_expected, got: sub_actual }
          break
        end

        {
          kind: :differs,
          idx: idx,
          row_class: actual[:class],
          path: field_diff[:path],
          expected: field_diff[:expected],
          got: field_diff[:got],
          expected_row: expected,
          got_row: actual
        }
      end

      # Walks parallel structures (Hash/Array/scalar) and returns the path,
      # expected leaf, and actual leaf at the first differing position.
      def self.first_difference(expected, actual, path)
        return [path, expected, actual] if expected.class != actual.class
        return [path, expected, actual] unless expected.is_a?(Array) || expected.is_a?(Hash)

        return diff_in_array(expected, actual, path) if expected.is_a?(Array)

        diff_in_hash(expected, actual, path)
      end

      def self.diff_in_array(expected, actual, path)
        [expected.length, actual.length].max.times do |i|
          return ["#{path}[#{i}]", expected[i], actual[i]] if i >= expected.length || i >= actual.length
          next if expected[i] == actual[i]

          return first_difference(expected[i], actual[i], "#{path}[#{i}]")
        end
        [path, expected, actual]
      end

      def self.diff_in_hash(expected, actual, path)
        (expected.keys | actual.keys).each do |key|
          return ["#{path}[#{key.inspect}]", expected[key], actual[key]] if !expected.key?(key) || !actual.key?(key)
          next if expected[key] == actual[key]

          return first_difference(expected[key], actual[key], "#{path}[#{key.inspect}]")
        end
        [path, expected, actual]
      end

      # Validates each expected row carries the required `:id`, `:class`,
      # `:payload` keys. Without this, an expected row of `{ id: 0, class:
      # :model }` would silently pass against any actual row whose payload
      # was nil — because the `==` check reads `expected[:payload]` as nil.
      def self.validate_expected_rows!(expected_rows)
        expected_rows.each_with_index do |row, i|
          unless row.is_a?(Hash)
            raise ArgumentError,
                  "match_flight_structure: expected row #{i} must be a Hash, got #{row.class}: #{row.inspect}"
          end

          missing = REQUIRED_EXPECTED_KEYS.reject { |k| row.key?(k) }
          next if missing.empty?

          raise ArgumentError,
                "match_flight_structure: expected row #{i} is missing required keys: #{missing.inspect}. " \
                "Each expected row must include :id, :class, and :payload."
        end
      end

      # Validates a predicate hash for `include_flight_row`. Unknown keys
      # (typos like `payloed:` or `clas:`) raise immediately so they don't
      # silently match any row via `row[:payloed]` returning nil.
      def self.validate_predicate!(predicate)
        unless predicate.is_a?(Hash)
          raise ArgumentError,
                "include_flight_row: predicate must be a Hash, got #{predicate.class}: #{predicate.inspect}"
        end
        raise ArgumentError, "include_flight_row: predicate cannot be empty" if predicate.empty?

        unknown = predicate.keys - KNOWN_ROW_KEYS
        return if unknown.empty?

        raise ArgumentError,
              "include_flight_row: predicate has unknown keys: #{unknown.inspect}. " \
              "Allowed keys: #{KNOWN_ROW_KEYS.inspect}."
      end

      def self.format_single(diff)
        case diff[:kind]
        when :missing
          row = diff[:expected_row]
          "Expected row #{diff[:idx]} (#{row[:class]}) was not produced.\n  expected: #{row.inspect}"
        when :extra
          row = diff[:actual_row]
          "Got unexpected row #{diff[:idx]} (#{row[:class]}): #{row.inspect}"
        else
          format_field_diff(diff)
        end
      end

      def self.format_field_diff(diff)
        <<~MSG.strip
          Expected Flight output to match structure.

          Row #{diff[:idx]} (#{diff[:row_class]}) differs at #{diff[:path]}:
            expected: #{diff[:expected].inspect}
            got:      #{diff[:got].inspect}

          Row #{diff[:idx]} (#{diff[:row_class]}) full diff:
            expected: #{diff[:expected_row][:payload].inspect}
            got:      #{diff[:got_row][:payload].inspect}
        MSG
      end

      # Builds the multi-row failure message: header naming the diff count,
      # AC3-specified wording for missing / extra / differing rows, and a
      # `Row N (<class>): ✓` summary line for every matching row so the
      # reader can see what passed.
      def self.format_multi(diffs, actual_rows, expected_rows)
        header = "Expected Flight output to match structure. #{diffs.length} rows differ:"
        total = [actual_rows.length, expected_rows.length].max
        diff_by_idx = diffs.to_h { |d| [d[:idx], d] }

        body = (0...total).map do |i|
          diff = diff_by_idx[i]
          if diff
            format_entry(diff)
          else
            row_class = (actual_rows[i] || expected_rows[i])[:class]
            "Row #{i} (#{row_class}): ✓"
          end
        end

        ([header, ""] + body).join("\n")
      end

      def self.format_entry(diff)
        case diff[:kind]
        when :missing
          row = diff[:expected_row]
          "Expected row #{diff[:idx]} (#{row[:class]}) was not produced.\n  expected: #{row.inspect}"
        when :extra
          row = diff[:actual_row]
          "Got unexpected row #{diff[:idx]} (#{row[:class]}): #{row.inspect}"
        else
          <<~ENTRY.strip
            Row #{diff[:idx]} (#{diff[:row_class]}) differs at #{diff[:path]}:
              expected: #{diff[:expected].inspect}
              got:      #{diff[:got].inspect}
          ENTRY
        end
      end

      # Subset / case-equality match used by `include_flight_row`. Plain
      # values use `==`; richer matchers (`hash_including`, `array_including`,
      # `kind_of`, regexes) use `===` which delegates to their custom logic.
      # Predicate keys are validated upfront by `validate_predicate!`, so
      # this method can assume every key is one of the known row keys.
      def self.row_matches?(row, predicate)
        predicate.all? do |key, expected_value|
          actual_value = row[key]
          case expected_value
          when Symbol, Numeric, NilClass, TrueClass, FalseClass
            expected_value == actual_value
          else
            # rubocop:disable Style/CaseEquality -- intentional: lets RSpec mock argument matchers
            # (hash_including, array_including, kind_of, etc.) drive predicate semantics via #===.
            expected_value === actual_value
            # rubocop:enable Style/CaseEquality
          end
        end
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
