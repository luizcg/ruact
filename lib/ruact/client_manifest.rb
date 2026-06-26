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
  #
  # Story 13.5 (FR100) — an entry MAY carry an optional, purely additive
  # +contract+ field when the component opts in by exporting +__ruactContract+
  # from its +.tsx+ (the Vite plugin extracts it names-only). Shape:
  #
  #   "LikeButton": {
  #     "id": ..., "name": ..., "chunks": [...],
  #     "contract": {
  #       "props":       { "postId" => "required", "initialCount" => "optional" },
  #       "slots":       { "header" => "optional" },          # optional
  #       "passthrough": false                                 # optional
  #     }
  #   }
  #
  # A component without the export has NO +contract+ key (back-compatible: every
  # existing manifest + reader is unaffected). {#contract_for} reads it for the
  # Story 13.5 preprocess-time call-site validator; +nil+ means "no contract →
  # no validation" (fail open).
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

    # Story 13.5 (FR100) — return the optional component +contract+ Hash for
    # +name+, or +nil+ when the component declared none (or is absent from the
    # manifest). Honors the same co-located/shared +resolve_key+ precedence as
    # {#reference_for}, so a co-located component's contract is found when the
    # call site's +controller_path+ is known. A pure read (no memoization, no
    # mutation) — safe on the frozen manifest, never raises for an unknown name
    # (the validator fails open). Consumed by {Ruact::ComponentContract} from
    # the ERB preprocessor.
    #
    # @param name [String] PascalCase component name (e.g. "LikeButton")
    # @param controller_path [String, nil] e.g. "posts" — biases toward a
    #   co-located key ("posts/_like_button") when present.
    # @return [Hash, nil] the contract Hash, or nil when none is declared.
    def contract_for(name, controller_path: nil)
      entry = entries_by_name[resolve_key(name, controller_path)]
      entry && entry["contract"]
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
        distance = StringDistance.damerau_levenshtein(target, comparable)
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

    # Returns the manifest key to use for +name+ given an optional +controller_path+.
    # Co-located key format: "<controller_path>/_<underscored_name>" (e.g. "posts/_like_button").
    # Co-located takes precedence when both keys exist.
    def resolve_key(name, controller_path)
      return name unless controller_path

      co_located = "#{controller_path}/_#{pascal_to_snake_case(name)}"
      include?(co_located) ? co_located : name
    end

    # Converts PascalCase component names to snake_case without requiring ActiveSupport.
    # Equivalent to ActiveSupport::Inflector.underscore for PascalCase inputs.
    def pascal_to_snake_case(name)
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
