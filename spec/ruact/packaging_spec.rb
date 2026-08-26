# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "ruact/packaging"

# Story 5.10 — the packaging predicate.
#
# `Ruact::Packaging.packaged?` answers one question — does this path go inside
# the published `.gem`? — for two callers that must never disagree: the gemspec,
# which builds `spec.files` from it, and `bin/release-gate`, which decides
# whether a pull request changed what a consumer installs.
#
# The examples below are in two halves. The first is the rule, stated against
# paths chosen because they are the near misses. The second is the rule applied
# to this repository's real tracked set, which is the half that would catch a
# widening nobody meant — a predicate can be right about every example here and
# still ship the wrong tree.
#
# WHAT IT DOES NOT PROMISE
#
#   That the gem is loadable. Whether the packaged set is *sufficient* is
#   decided by unpacking a built gem and requiring it, which is a release-time
#   act, not a suite-time one.
RSpec.describe Ruact::Packaging, :story_5_10 do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:tracked) do
    IO.popen(%w[git ls-files -z], chdir: root.to_s, err: IO::NULL) do |ls|
      ls.readlines("\x0", chomp: true)
    end
  end

  describe ".packaged?" do
    it "packages the trees a consumer of the installed gem reaches" do
      expect(described_class).to be_packaged("lib/ruact.rb")
      expect(described_class).to be_packaged("lib/generators/ruact/install/templates/AGENTS.md.tt")
      expect(described_class).to be_packaged("sig/ruact.rbs")
      expect(described_class).to be_packaged("vendor/javascript/vite-plugin-ruact/index.js")
    end

    it "packages the top-level documents, by shape rather than by roster" do
      expect(described_class).to be_packaged("README.md")
      expect(described_class).to be_packaged("LICENSE.txt")
      expect(described_class).to be_packaged("SOMETHING-NOBODY-HAS-WRITTEN-YET.md"),
                                 "a new top-level document has to ship without anyone editing the predicate"
    end

    it "refuses the top-level files that are not documents" do
      %w[ruact.gemspec Gemfile Gemfile.lock Rakefile .rubocop.yml .gitignore .codecov.yml].each do |path|
        expect(described_class).not_to be_packaged(path), "#{path} is not something a consumer installs"
      end
    end

    it "refuses the trees that exist for developing the gem, not for using it" do
      %w[spec/spec_helper.rb bench/render.rb docs/internal/decisions/server-functions-api.md
         .github/workflows/ci.yml bin/release].each do |path|
        expect(described_class).not_to be_packaged(path)
      end
    end

    # `vendor/javascript/` is public surface; the rest of `vendor/` is this
    # repository's own machinery, and the two are one prefix apart. Stated
    # against paths rather than against the tracked set, because everything
    # tracked under `vendor/` today is already the JavaScript tree — so a
    # widening to the whole of `vendor/` would be invisible to any statement
    # made about what is tracked, and would start shipping the next thing
    # vendored here.
    it "keeps the rest of vendor/ out, however plausible the neighbour" do
      expect(described_class).not_to be_packaged("vendor/bundle/ruby/3.3.0/gems/nokogiri-1.18.0/lib/nokogiri.rb")
      expect(described_class).not_to be_packaged("vendor/cache/rails-8.0.0.gem")
    end

    # A deleted path is still a path, and Gate A is applied to
    # `git diff --name-only`, where deletions and additions look alike. The
    # predicate answers about the shape, so it has nothing to say about
    # existence — which is the property that makes a deletion count.
    it "answers about a path that does not exist on disk" do
      expect(root.join("lib/ruact/gone.rb")).not_to exist
      expect(described_class).to be_packaged("lib/ruact/gone.rb")
    end
  end

  describe ".packaged_paths" do
    it "preserves order and drops the rest" do
      expect(described_class.packaged_paths(%w[Gemfile lib/ruact.rb spec/a_spec.rb README.md]))
        .to eq(%w[lib/ruact.rb README.md])
    end
  end

  describe "applied to this repository" do
    it "packages the runtime the library requires, entry point included" do
      required = root.join("lib/ruact.rb").read.scan(/require_relative "([^"]+)"/).flatten
      paths = ["lib/ruact.rb", *required.map { |name| "lib/#{name}.rb" }]

      expect(paths.reject { |path| described_class.packaged?(path) }).to be_empty
    end

    it "leaves the development trees out of the gem entirely" do
      leaked = described_class.packaged_paths(tracked)
                              .select { |path| path.start_with?("spec/", "bench/", "docs/", ".github/", "bin/") }

      expect(leaked).to be_empty,
                        "these tracked paths would ship inside the gem: #{leaked.first(5).inspect}"
    end
  end
end
