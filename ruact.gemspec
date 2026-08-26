# frozen_string_literal: true

require_relative "lib/ruact/version"
require_relative "lib/ruact/packaging"

Gem::Specification.new do |spec|
  spec.name = "ruact"
  spec.version = Ruact::VERSION
  spec.authors = ["Luiz Garcia"]
  spec.email = ["luizcg@gmail.com"]

  spec.summary = "React Server Components for Rails — render React components from ERB using the Flight wire format."
  spec.description = <<~DESC
    ruact renders React components straight from your ERB views: write a PascalCase
    tag, pass a Ruby value as a prop, and React hydrates it in the browser over the
    Flight wire format. Server functions and queries are drawn from your existing
    route table, so there is no hand-written JSON layer to keep in sync and no Node
    process in production.
  DESC
  spec.homepage = "https://ruact.dev/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/luizcg/ruact"
  spec.metadata["changelog_uri"] = "https://github.com/luizcg/ruact/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/luizcg/ruact/issues"
  spec.metadata["documentation_uri"] = "https://ruact.dev"
  spec.metadata["rubygems_mfa_required"] = "true"

  # What ships is decided by `Ruact::Packaging`, not here. Story 5.10 moved
  # the rule out of this file because `bin/release-gate` has to ask the same
  # question — "did this pull request change what a consumer installs?" — and
  # two copies of a packaging rule drift the first time the rule changes.
  # `Ruact::Packaging` is build-time code: nothing under `lib/` requires it,
  # and nothing at runtime may come to.
  spec.files = Ruact::Packaging.packaged_paths(
    IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
      ls.readlines("\x0", chomp: true)
    end
  )
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.15"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
