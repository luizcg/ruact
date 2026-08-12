# frozen_string_literal: true

require_relative "lib/ruact/version"

Gem::Specification.new do |spec|
  spec.name = "ruact"
  spec.version = Ruact::VERSION
  spec.authors = ["Luiz Garcia"]
  spec.email = ["luizcg@gmail.com"]

  spec.summary = "React Server Components for Rails — render React components from ERB using the Flight wire format."
  spec.homepage = "https://ruact.dev/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/luizcg/ruact"
  spec.metadata["changelog_uri"] = "https://github.com/luizcg/ruact/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/luizcg/ruact/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Re-run-5 (2026-05-15) — the `vendor/javascript/**` tree is part of
  # the gem's PUBLIC surface: the Vite plugin imports
  # `ruact/server-functions-runtime` (resolved via the bundled package
  # under `vendor/javascript/ruact-server-functions-runtime/`) and
  # auto-aliases that path at boot. Pre-batch the gemspec blanket-
  # excluded `vendor/` to keep the legacy Yarn vendoring out of the
  # published gem; the exclusion has to be narrower now. We keep
  # `vendor/bundle/` out (that's the local Bundler install dir) but
  # ship every other `vendor/` path. Without this, a `gem push`-ed
  # release would generate import paths to files that don't exist on
  # the consumer's disk.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore vendor/bundle/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.15"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
