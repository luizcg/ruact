# frozen_string_literal: true

require "json"

module Ruact
  # Reads the react-client-manifest.json emitted by the Vite plugin and
  # resolves component names to Flight ClientReferences.
  #
  # Manifest format (one entry per "use client" export):
  #   {
  #     "LikeButton": {
  #       "id":     "/assets/LikeButton-abc123.js",
  #       "chunks": ["/assets/LikeButton-abc123.js"],
  #       "name":   "LikeButton"
  #     },
  #     "posts/_like_button": {
  #       "id":     "/assets/posts/_like_button-abc123.js",
  #       "chunks": ["/assets/posts/_like_button-abc123.js"],
  #       "name":   "default"
  #     }
  #   }
  class ClientManifest
    # Used by Flight::Serializer to produce I rows.
    # Returns the metadata array the client expects: [id, name, chunks]
    def resolve(module_id, _export_name)
      entry = by_module_id(module_id)
      raise "ClientManifest: no entry for module_id=#{module_id.inspect}" unless entry

      [entry["id"], entry["name"], entry["chunks"]]
    end

    # Returns true if +name+ is a top-level key in the manifest data.
    # Used by the dual-path resolver to check co-located key existence before fallback.
    def include?(name)
      entries_by_name.key?(name)
    end

    # Resolve a component name (e.g. "LikeButton") → ClientReference.
    #
    # When +controller_path+ is provided (e.g. "posts"), the resolver first
    # looks for a co-located key ("posts/_like_button"). If found, it returns
    # that reference; otherwise it falls back to the shared PascalCase key.
    #
    # Returns the same object for repeated calls with the same resolved key
    # (needed for dedup by object_id in Flight::Serializer).
    #
    # Raises +Ruact::ManifestError+ when the resolved name is not found. The
    # error message includes a Damerau-Levenshtein closest-match suggestion
    # (Story 7.4) when a manifest entry within distance 2 exists, or a
    # file-path hint suggesting where to add the missing component otherwise.
    # When +controller_path+ is given the closest-match scan biases toward
    # co-located keys so a typo inside +posts/show.html.erb+ surfaces the
    # +posts/_like_button+ suggestion before the shared +LikeButton+ entry.
    def reference_for(name, controller_path: nil)
      @reference_cache ||= {}
      key = resolve_key(name, controller_path)
      @reference_cache[key] ||= begin
        entry = entries_by_name[key]
        raise ManifestError, build_unknown_component_message(name, controller_path) unless entry

        Flight::ClientReference.new(module_id: entry["id"], export_name: entry["name"])
      end
    end

    # Load from a file path (JSON).
    # Pre-warms the reference cache and freezes the manifest so it cannot be
    # mutated at runtime (AC#5). Pre-warming is required because Ruby's freeze
    # is shallow: instance variable assignment on a frozen object raises
    # FrozenError, so @reference_cache must already be set before freeze.
    def self.load(path)
      raw      = File.read(path)
      data     = JSON.parse(raw)
      manifest = from_hash(data)
      data.each_key { |name| manifest.reference_for(name) }
      manifest.freeze
    end

    # Build from an already-parsed Hash (useful in tests).
    # The +@reference_cache+ ivar is initialized eagerly so the freeze +
    # first-lookup path works even when +data+ is empty (otherwise
    # +reference_for+ would raise +FrozenError+ trying to memoize on a
    # frozen instance).
    def self.from_hash(data)
      manifest = new
      manifest.instance_variable_set(:@data, data)
      manifest.instance_variable_set(:@reference_cache, {})
      manifest
    end

    private

    # Story 7.4: build the ManifestError message for a missing component,
    # using the AC3 verbatim multi-line "ruact:" shape with a Damerau-
    # Levenshtein closest-match suggestion (or a file-path fallback hint).
    def build_unknown_component_message(name, controller_path = nil)
      suggestion = closest_match_for(name, entries_by_name.keys, controller_path)
      hint = if suggestion
               %(Did you mean "#{suggestion}"?)
             else
               "Did you mean to add app/javascript/components/#{name}.jsx and rebuild Vite?"
             end

      <<~MSG.strip
        ruact: Component #{name.inspect} not found in manifest.
          #{hint}
          Did you run the Vite build? Run 'npm run build' or start the Vite dev server.
      MSG
    end

    # Returns the manifest key whose comparable name is within Damerau-
    # Levenshtein distance 2 of +name+ (case-insensitive), preferring the
    # smallest distance. Returns +nil+ if no key qualifies.
    #
    # Comparison-key normalization (so a typo like "LikeButtoon" can match
    # the co-located key "posts/_like_button"):
    #
    # - Shared PascalCase keys (e.g. "LikeButton") compare as-is.
    # - Co-located keys (e.g. "posts/_like_button") compare as the basename
    #   in PascalCase ("LikeButton"); the original key is what gets returned
    #   so the developer sees the actual manifest entry name.
    #
    # When +controller_path+ is given, the matching logic prefers keys
    # scoped to that path (e.g. "posts/_*") so a typo inside posts/show
    # surfaces "posts/_like_button" before the shared "LikeButton" — even
    # if both tie at the same distance.
    def closest_match_for(name, pool, controller_path = nil)
      target = name.downcase
      best_key = nil
      best_distance = 3 # threshold + 1
      best_in_scope = false

      pool.each do |key|
        comparable = comparable_name_for(key).downcase
        distance = self.class.send(:damerau_levenshtein_distance, target, comparable)
        next if distance > 2

        in_scope = controller_path && key.start_with?("#{controller_path}/")
        next unless distance < best_distance || (distance == best_distance && in_scope && !best_in_scope)

        best_distance = distance
        best_key = key
        best_in_scope = in_scope
      end

      best_key
    end

    # Normalize a manifest key for comparison purposes. Co-located keys
    # ("posts/_like_button") collapse to their PascalCase basename
    # ("LikeButton"); shared keys are returned as-is.
    def comparable_name_for(key)
      return key unless key.include?("/")

      basename = key.split("/").last.delete_prefix("_")
      basename.split("_").map(&:capitalize).join
    end

    # Damerau-Levenshtein distance — like classic Levenshtein but treats
    # an adjacent transposition (e.g. "ke"↔"ek") as a single edit. Component
    # names are short (≤ 30 chars in practice) so the full O(m·n) DP table
    # is fine; the readability win over the two-row Levenshtein trick is
    # worth the extra ~30 cells of allocation in the failure path.
    # rubocop:disable Metrics/AbcSize
    def self.damerau_levenshtein_distance(left, right)
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
    private_class_method :damerau_levenshtein_distance

    # Returns the manifest key to use for +name+ given an optional +controller_path+.
    # Co-located key format: "<controller_path>/_<underscored_name>" (e.g. "posts/_like_button").
    # Co-located takes precedence when both keys exist.
    def resolve_key(name, controller_path)
      return name unless controller_path

      co_located = "#{controller_path}/_#{rsc_underscore(name)}"
      include?(co_located) ? co_located : name
    end

    # Converts PascalCase component names to snake_case without requiring ActiveSupport.
    # Equivalent to ActiveSupport::Inflector.underscore for PascalCase inputs.
    def rsc_underscore(name)
      name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    def data
      @data || {}
    end

    # Index by component name. Today the manifest hash is already keyed by
    # name, so this is a thin alias rather than a new index. Avoid lazy
    # memoization here because the manifest is frozen after +load+ — any
    # +@entries_by_name ||= ...+ assignment on a frozen instance would
    # raise +FrozenError+.
    def entries_by_name
      data
    end

    def by_module_id(id)
      data.values.find { |entry| entry["id"] == id }
    end
  end
end
