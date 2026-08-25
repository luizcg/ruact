# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "yaml"

# Story 5.8 — the contributing gate, living INSIDE the repository it guards.
#
# `CONTRIBUTING.md` is the first thing an outside contributor reads, and this is
# a PUBLIC repository whose planning happens somewhere they cannot see. Two
# failure modes follow from that, and neither is visible to a human reviewer
# reading a diff:
#
#   1. the document instructs the reader to do something only the maintainer
#      can do — clone a private repository, open a path that exists nowhere in
#      this checkout, run a script that lives on the other side of a boundary;
#   2. the document goes stale against the code it describes, which is how the
#      other contributing guide in this project ended up telling readers to use
#      a class that had been deleted and a pattern a linter now rejects.
#
# The epic that asked for this file proposed a word-presence grep as the guard
# ("the file exists and contains the words 'submodule' and 'two-repo'"). That is
# not a gate: a document can contain both words and be entirely false — the
# stale one did. `spec/readme_spec.rb` learned the same lesson the expensive
# way, in three consecutive review rounds, and the shape that survived is the
# shape used here: statements that are TOTAL, derived from artifacts that cannot
# drift independently of what they describe.
#
# What each example promises is stated by its own name and its own failure
# message; this comment deliberately does not restate them, because prose beside
# a gate, saying what the gate already guarantees, is an ungated second copy that
# drifts.
#
# WHAT IT DOES NOT PROMISE
#
#   Truth. No spec can assert that the prose describes the project accurately —
#   only that the mechanical claims inside it still match the repository. The
#   command blocks are pinned, not executed; a block can be pinned and wrong.
#   Story 5.8 ran the `path:` block end to end in a throwaway Rails app and
#   recorded the evidence, and re-running it is what a change to that block
#   costs.
#
#   Nor does it read anything outside this repository. That is deliberate and it
#   is the same one-way rule `spec/readme_spec.rb` states: a public artifact
#   that cannot be verified in its own repository is not verifiable.
RSpec.describe "CONTRIBUTING.md", :story_5_8 do
  subject(:contributing) { contributing_path.read }

  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }
  let(:contributing_path) { root.join("CONTRIBUTING.md") }
  let(:workflow) { YAML.safe_load_file(root.join(".github/workflows/ci.yml").to_s, aliases: true) }

  # Both lists live in `spec/support/markdown_gate.rb`, shared with
  # `spec/releasing_spec.rb`. The rationale for each is written there, beside
  # the list, so there is one copy of both.
  let(:private_side) { Ruact::Spec::MarkdownGate::PRIVATE_SIDE }
  let(:enforcement_claims) { Ruact::Spec::MarkdownGate::ENFORCEMENT_CLAIMS }

  # The command spine, byte for byte. A contributor copies these; a drifted
  # block is a broken promise that only shows up on somebody else's machine.
  #
  # The last one — the working-tree trial — ran end to end on 2026-08-25 against
  # Rails 8.1.3.1 / Ruby 3.4.5: the app booted, the generated `vite.config.js`
  # imported the Vite plugin from the checkout, and the page rendered the
  # component out of the Flight payload.
  let(:command_spine) do
    {
      "setup" => <<~BASH,
        git clone https://github.com/luizcg/ruact.git
        cd ruact
        bundle install
      BASH
      "JavaScript setup" => <<~BASH,
        cd vendor/javascript/ruact-server-functions-runtime && npm install
        cd ../vite-plugin-ruact && npm ci
      BASH
      "local checks" => <<~BASH,
        bundle exec rspec
        bundle exec rubocop --format github
        rm -rf .yardoc doc && bundle exec yard --fail-on-warning
        bundle exec rake benchmark:memory
      BASH
      "JavaScript checks" => <<~BASH,
        cd vendor/javascript/vite-plugin-ruact
        npm test
        npm run typecheck
      BASH
      "matrix cell" => <<~BASH,
        RAILS_VERSION=7.2 bundle install && bundle exec rspec
      BASH
      # Single-quoted delimiter: `\n`, `%s` and `$RUACT` are literal bytes the
      # reader copies, not things Ruby should expand on the way past.
      "working-tree trial in a real app" => <<~'BASH'
        export RUACT=/absolute/path/to/your/ruact

        rails new myapp --skip-javascript
        cd myapp
        printf '\ngem "ruact", path: "%s"\n' "$RUACT" >> Gemfile
        bundle install
        bin/rails generate ruact:install
        bin/dev
      BASH
    }
  end

  # Shared recognisers; see `spec/support/markdown_gate.rb`.
  def markdown_link_targets(markdown)
    Ruact::Spec::MarkdownGate.link_targets(markdown)
  end

  def relative(targets)
    Ruact::Spec::MarkdownGate.relative(targets)
  end

  def bash_blocks(markdown)
    Ruact::Spec::MarkdownGate.bash_blocks(markdown)
  end

  # The job table is delimited in the document itself, so this reads the list the
  # reader sees rather than every backticked word in the file.
  def documented_ci_jobs
    region = contributing[/<!-- ci-jobs:begin -->(.*?)<!-- ci-jobs:end -->/m, 1]

    raise "CONTRIBUTING.md has no <!-- ci-jobs:begin --> … <!-- ci-jobs:end --> region" if region.nil?

    region.scan(/^\|\s*`([a-z0-9-]+)`\s*\|/).flatten
  end

  def workflow_pr_jobs
    workflow.fetch("jobs").keys - ["release"]
  end

  it "exists and has substance" do
    expect(contributing_path).to exist
    expect(contributing.strip.length).to be > 2_000,
                                         "CONTRIBUTING.md is #{contributing.strip.length} bytes — too " \
                                         "short to answer setup, checks, local testing and routing."
  end

  it "links only to files that exist in this repository" do
    targets = relative(markdown_link_targets(contributing))
    missing = targets.reject { |target| root.join(target.split("#").first.to_s).exist? }

    expect(targets).not_to be_empty, "expected CONTRIBUTING.md to link at least one repo-relative file"
    expect(missing).to be_empty,
                       "CONTRIBUTING.md links files that do not exist in this repository: #{missing.inspect}"
  end

  it "names nothing that exists only in the private repository" do
    offenders = private_side.filter_map { |pattern| pattern.source if contributing.match?(pattern) }

    expect(offenders).to be_empty,
                         "CONTRIBUTING.md names private-side vocabulary (#{offenders.inspect}). Its reader " \
                         "can see this repository and nothing else, so a path they cannot open is worse " \
                         "than no path at all."
  end

  it "sends the reader to exactly one repository — this one" do
    expect(contributing.scan(/git clone \S+/))
      .to eq(["git clone https://github.com/luizcg/ruact.git"]),
          "CONTRIBUTING.md tells the reader to clone something other than this repository. Everything it " \
          "asks for has to be runnable with the public checkout alone."
  end

  # The strongest anti-rot statement available here: the list is not maintained,
  # it is derived. Renaming a job in the workflow reddens this without anybody
  # remembering that a document mentions it.
  it "documents exactly the CI jobs that run on a pull request" do
    expect(documented_ci_jobs.sort).to eq(workflow_pr_jobs.sort),
                                       "the CI jobs named in CONTRIBUTING.md " \
                                       "(#{documented_ci_jobs.sort.inspect}) are not the jobs in " \
                                       ".github/workflows/ci.yml (#{workflow_pr_jobs.sort.inspect}). " \
                                       "`release` is excluded on purpose — it never runs on a pull request."
  end

  it "does not claim a check is required, because none of them is" do
    offenders = enforcement_claims.filter_map { |pattern| pattern.source if contributing.match?(pattern) }

    expect(offenders).to be_empty,
                         "CONTRIBUTING.md claims a check gates merging (#{offenders.inspect}). This " \
                         "repository's `main` has no branch protection and no rulesets — the workflow's " \
                         "own \"Required status check\" comments are aspirational. Say what the " \
                         "workflow does, not what it decides."
  end

  # Not "each pinned block appears somewhere" — that is satisfied by one hidden
  # exact copy while the block the reader actually reaches says something else.
  it "pins every bash block a contributor could copy, in the order they appear" do
    actual = bash_blocks(contributing)
    expected = command_spine.values

    expect(actual.length).to eq(expected.length),
                             "CONTRIBUTING.md has #{actual.length} ```bash block(s); this spec pins " \
                             "#{expected.length}. A block a reader can copy and this gate does not watch " \
                             "is exactly how the commands drift. Pin it or drop it."

    actual.zip(expected, command_spine.keys).each do |got, want, name|
      expect(got).to eq(want),
                     "the #{name} block in CONTRIBUTING.md drifted from the literal this spec pins. These " \
                     "are commands a contributor copies; change both or neither, and re-run the block " \
                     "before you do."
    end
  end

  it "is reachable from the page GitHub renders" do
    expect(root.join("README.md").read).to include("[CONTRIBUTING.md](CONTRIBUTING.md)"),
                                           "README.md does not link CONTRIBUTING.md, so the guide is " \
                                           "invisible to anyone landing on the repository page."
  end
end
