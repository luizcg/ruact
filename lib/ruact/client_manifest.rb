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
    # Raises if the resolved name is not found in the manifest.
    def reference_for(name, controller_path: nil)
      @reference_cache ||= {}
      key = resolve_key(name, controller_path)
      @reference_cache[key] ||= begin
        entry = entries_by_name[key]
        unless entry
          raise ManifestError,
                "Component #{name.inspect} not found in manifest — " \
                "Did you run the Vite build? Run 'npm run build' or start the Vite dev server."
        end

        Flight::ClientReference.new(module_id: entry["id"], export_name: name)
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
    def self.from_hash(data)
      manifest = new
      manifest.instance_variable_set(:@data, data)
      manifest
    end

    private

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
      @data ||= {}
    end

    # Index by component name for fast lookup
    def entries_by_name
      @entries_by_name ||= data
    end

    def by_module_id(id)
      data.values.find { |entry| entry["id"] == id }
    end
  end
end
