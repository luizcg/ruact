# frozen_string_literal: true

require "spec_helper"
require "pathname"

# Story 5.14 — the README gate that lives INSIDE this repository.
#
# `README.md` is not an ordinary readme: GitHub renders it on the gem's own
# repository page, `source_code_uri` points at it, and `spec.files` packages it
# *inside* the built `.gem`. Until this story it was still `bundle gem`
# boilerplate ("TODO: Delete this and the text below"), and that boilerplate had
# already shipped to RubyGems.
#
# The planning monorepo has a command-spine gate
# (`docs/examples/getting-started/scripts/check-commands.mjs`) that reads this
# file through the `gem/` submodule and checks its quick start against ONE
# canonical greenfield sequence — the SPINE, which is the single source of
# truth. But a merge in THIS repository fires nothing over there, so a
# README-only PR here would stay unchecked until somebody bumped the submodule
# pointer.
#
# Hence the deliberate duplication below: `expected_quick_start` is a literal
# copy of the quick-start block, owned by this spec, and the monorepo gate
# verifies that literal against the canonical SPINE. The dependency runs one way
# only — this spec reads nothing outside the gem repository, because a public
# artifact that cannot be verified in its own repository is not verifiable.
RSpec.describe "README.md", :story_5_14 do
  subject(:readme) { root.join("README.md").read }

  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }

  # Every literal `bundle gem` leaves behind. Each one was present before this
  # story; any of them coming back means the scaffolding was re-pasted.
  let(:boilerplate) do
    [
      "TODO:",
      "UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG",
      "[USERNAME]",
      "Welcome to your new gem",
      "Put your Ruby code in the file",
      "bin/console",
      "bundle exec rake release"
    ]
  end

  # Harness-only gem sources. They exist so the monorepo's playgrounds can test
  # the working tree; a reader who copies one installs nothing.
  let(:path_gem_sources) do
    [
      /(^|\s)gem\s+["']ruact["']\s*,\s*path:/,
      /--path(\s|=)/
    ]
  end

  # The quick-start block, byte for byte. Changing it here without changing the
  # monorepo SPINE (or the other way round) turns the monorepo gate red.
  let(:expected_quick_start) do
    <<~BASH
      # 1. A throwaway app to try it in
      rails new myapp --skip-javascript && cd myapp

      # 2. Add the gem
      bundle add ruact

      # 3. Write the config, the layout wiring and an AGENTS.md — then run npm install
      rails generate ruact:install

      # 4. Rails + Vite, one command
      bin/dev
    BASH
  end

  # `[text](target)`, inline-title form allowed. Absolute URLs, anchors and
  # mailto: links are somebody else's problem; on-disk targets are ours.
  def relative_link_targets(markdown)
    markdown.scan(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten.reject do |target|
      target.start_with?("http://", "https://", "#", "mailto:")
    end
  end

  def bash_blocks(markdown)
    markdown.scan(/^```bash[ \t]*\n(.*?)^```/m).flatten
  end

  it "carries none of the `bundle gem` boilerplate" do
    present = boilerplate.select { |literal| readme.include?(literal) }

    expect(present).to be_empty,
                       "README.md still carries bundler scaffolding: #{present.inspect}"
  end

  it "links only to files that exist in this repository" do
    targets = relative_link_targets(readme)
    missing = targets.reject { |target| root.join(target.split("#").first.to_s).exist? }

    expect(targets).not_to be_empty, "expected the README to link at least one repo-relative file"
    expect(missing).to be_empty,
                       "README.md links files that do not exist in the gem repository: #{missing.inspect}"
  end

  it "shows no harness-only `path:` gem source a reader could copy" do
    offenders = path_gem_sources.filter_map { |pattern| pattern.source if readme.match?(pattern) }

    expect(offenders).to be_empty,
                         "README.md shows a harness-only gem source (#{offenders.inspect}) — " \
                         "a reader who copies it installs nothing"
  end

  it "pins the quick start to the canonical greenfield sequence" do
    expect(bash_blocks(readme).first).to eq(expected_quick_start),
                                         "the README quick start drifted. It is checked against the monorepo's " \
                                         "canonical SPINE (docs/examples/getting-started/scripts/" \
                                         "check-commands.mjs); change both or neither."
  end

  it "keeps the quick start in a ```bash fence, the only language the monorepo gate reads" do
    expect(readme).to include("```bash\n#{expected_quick_start}```")
  end
end
