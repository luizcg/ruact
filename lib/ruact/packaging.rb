# frozen_string_literal: true

module Ruact
  # What goes inside the published `.gem`, as a predicate rather than a list.
  #
  # There is exactly one writer of this rule. `ruact.gemspec` calls it to build
  # `spec.files`, and `bin/release-gate` calls it to decide whether a pull
  # request changed the bytes a consumer installs. A hand-kept path list on
  # either side would be a second copy of the packaging rule, and it would drift
  # from this one the first time the rule changed — which is the whole reason
  # the gate does not carry its own.
  #
  # This file is **not** required from `lib/ruact.rb`. It is build-time code
  # that happens to live under `lib/` so the gemspec can `require_relative` into
  # it; nothing at runtime loads it, and nothing at runtime may come to depend
  # on it.
  #
  # WHAT IT DOES NOT PROMISE
  #
  #   That the path exists, is tracked, or is readable. It answers a question
  #   about a path's shape and nothing else; both callers hand it paths that
  #   `git` has already vouched for.
  module Packaging
    # Directory trees a consumer of the installed gem actually reaches:
    # `lib/` is the library, `sig/` is its RBS surface, and
    # `vendor/javascript/` is public surface too — the bundled Vite plugin and
    # browser runtime are resolved by filesystem path off the installed gem, so
    # a release that left them out would generate imports to files that do not
    # exist on the consumer's disk.
    TREES = %w[lib/ sig/ vendor/javascript/].freeze

    # `vendor/bundle/` is the local Bundler install directory. It is not under
    # any of {TREES} today; the exclusion is here so that widening a tree above
    # cannot quietly start packaging it.
    EXCLUDED_TREES = %w[vendor/bundle/].freeze

    # The documents that ship beside the code, expressed as a shape rather than
    # a roster: a tracked file at the top level whose extension is `.md` or
    # `.txt`. That covers the readme, the changelog, the licence, the security
    # policy and both guides, and it keeps covering the next one without anyone
    # remembering to add it here.
    #
    # It also decides the near misses by construction. `ruact.gemspec`,
    # `Gemfile`, `Gemfile.lock`, `Rakefile`, `.rubocop.yml` and `.gitignore` are
    # all top-level and none of them is a document, so none of them ships.
    ROOT_DOCUMENT = %r{\A[^/]+\.(?:md|txt)\z}i

    # Does this repository-relative path go inside the published gem?
    #
    # @param path [String] a repository-relative path, as `git ls-files` and
    #   `git diff --name-only` both emit it (forward slashes, no leading `./`)
    # @return [Boolean] true when the path is part of what a consumer installs
    def self.packaged?(path)
      return false if EXCLUDED_TREES.any? { |tree| path.start_with?(tree) }

      TREES.any? { |tree| path.start_with?(tree) } || path.match?(ROOT_DOCUMENT)
    end

    # The packaged subset of a list of repository-relative paths, order
    # preserved.
    #
    # @param paths [Enumerable<String>] repository-relative paths
    # @return [Array<String>] those of them that go inside the published gem
    def self.packaged_paths(paths)
      paths.select { |path| packaged?(path) }
    end
  end
end
