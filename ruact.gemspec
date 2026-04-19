# frozen_string_literal: true

require_relative "lib/ruact/version"

Gem::Specification.new do |spec|
  spec.name = "ruact"
  spec.version = Ruact::VERSION
  spec.authors = ["Luiz Garcia"]
  spec.email = ["luizcg@gmail.com"]

  spec.summary = "React Server Components for Rails — render React components from ERB using the Flight wire format."
  spec.homepage = "https://luizcg.github.io/ruact/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/luizcg/ruact"
  spec.metadata["changelog_uri"] = "https://github.com/luizcg/ruact/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/luizcg/ruact/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore vendor/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.15"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
