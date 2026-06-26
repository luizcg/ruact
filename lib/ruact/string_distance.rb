# frozen_string_literal: true

module Ruact
  # Damerau-Levenshtein string distance + a "did you mean?" closest-match
  # helper, factored out of {Ruact::ClientManifest} (Story 7.4) so the
  # Story 13.5 component-contract validator can reuse the SAME closest-match
  # grain for typo'd prop/slot names ("did you mean `postId`?") without
  # duplicating the algorithm.
  #
  # Names are short (≤ 30 chars in practice) so the full O(m·n) DP table is
  # fine — the readability win over the two-row trick is worth ~30 cells.
  module StringDistance
    # Damerau-Levenshtein distance — like classic Levenshtein but treats an
    # adjacent transposition (e.g. "ke"↔"ek") as a single edit.
    #
    # @param left [String]
    # @param right [String]
    # @return [Integer] the edit distance
    # rubocop:disable Metrics/AbcSize
    def self.damerau_levenshtein(left, right)
      return right.length if left.empty?
      return left.length if right.empty?

      m = left.length
      n = right.length
      d = Array.new(m + 1) { Array.new(n + 1, 0) }
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }

      (1..m).each do |i|
        (1..n).each do |j|
          cost = left[i - 1] == right[j - 1] ? 0 : 1
          d[i][j] = [
            d[i - 1][j] + 1,        # deletion
            d[i][j - 1] + 1,        # insertion
            d[i - 1][j - 1] + cost  # substitution
          ].min
          if i > 1 && j > 1 && left[i - 1] == right[j - 2] && left[i - 2] == right[j - 1]
            d[i][j] = [d[i][j], d[i - 2][j - 2] + cost].min
          end
        end
      end

      d[m][n]
    end
    # rubocop:enable Metrics/AbcSize

    # Returns the entry in +pool+ within Damerau-Levenshtein distance +max+ of
    # +name+ (case-insensitive), preferring the smallest distance. Returns +nil+
    # when nothing qualifies.
    #
    # @param name [String] the typo'd name to match
    # @param pool [Array<String>] candidate names
    # @param max [Integer] inclusive distance threshold (default 2)
    # @return [String, nil]
    def self.closest_match(name, pool, max: 2)
      target = name.downcase
      best = nil
      best_distance = max + 1

      pool.each do |candidate|
        distance = damerau_levenshtein(target, candidate.downcase)
        next if distance > max || distance >= best_distance

        best_distance = distance
        best = candidate
      end

      best
    end
  end
end
