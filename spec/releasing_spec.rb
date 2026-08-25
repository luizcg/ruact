# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "yaml"

# Story 5.9 — the release gate, living INSIDE the repository it guards.
#
# `RELEASING.md` ships inside every published `.gem`, so it is a public artifact
# in the strongest sense available here: a reader can be holding it without ever
# having seen this repository's planning, its monorepo, or its history.
#
# The document it replaced had rotted in a way no reviewer catches by reading a
# diff, because nothing in any one diff is wrong: the process moved into CI one
# story at a time, and the file kept describing the hand steps that used to do
# the same work. Following it end to end would have hand-edited a file CI
# rewrites and hand-published a version CI had already published.
#
# So the statements here are derived from artifacts that cannot drift
# independently of what they describe — the workflow for the trigger, this
# repository's own files for the links — rather than from a word-presence grep,
# which a false document passes as easily as a true one.
#
# WHAT IT DOES NOT PROMISE
#
#   Truth. No spec can assert that the prose describes the release accurately,
#   only that its mechanical claims still match the repository. The command
#   blocks are pinned, not executed.
#
#   Nor does it read anything outside this repository, for the same one-way
#   reason `spec/readme_spec.rb` states: a public artifact that cannot be
#   verified in its own repository is not verifiable.
RSpec.describe "RELEASING.md", :story_5_9 do
  subject(:releasing) { releasing_path.read }

  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }
  let(:releasing_path) { root.join("RELEASING.md") }
  let(:workflow) { YAML.safe_load_file(root.join(".github/workflows/ci.yml").to_s, aliases: true) }
  let(:release_condition) { workflow.dig("jobs", "release", "if").to_s }

  # Steps this process does not perform, mapped to what performs them instead.
  # Every one of these was a numbered instruction in the file this replaced.
  let(:hand_steps) do
    {
      "npm publish" => "nothing is published to npm — the Vite plugin ships inside the gem",
      "npm unpublish" => "there is nothing on npm to roll back",
      "gem build" => "the release job builds the gem",
      "gem push" => "the release job uploads it, over OIDC, with no interactive step",
      "gem signin" => "there is no interactive credential to sign in with",
      "git tag" => "the release job tags the commit it just created",
      "VERSION = " => "the release job writes lib/ruact/version.rb; a hand-edited copy is a second writer",
      /(edit|bump|update|change|set)\s+(the\s+)?[`'"]?\S*version\.rb/i =>
        "the release job owns lib/ruact/version.rb — telling the reader to write it makes two writers",
      "release/v" => "there is no release branch — a release is a merge to main with the variable on"
    }
  end

  # The command spine, byte for byte. These are the commands that turn
  # publication on and off and the one that says whether it worked; a drifted
  # block here costs a version nobody asked for.
  let(:command_spine) do
    {
      "turn publication on" => <<~BASH,
        gh variable set RUACT_AUTO_RELEASE -b true -R luizcg/ruact
      BASH
      "turn publication off" => <<~BASH,
        gh variable delete RUACT_AUTO_RELEASE -R luizcg/ruact
      BASH
      "verify" => <<~BASH,
        curl -s https://rubygems.org/api/v1/versions/ruact/latest.json
      BASH
      "find the run that should have released" => <<~BASH,
        gh run list --branch main -L 3
        gh run rerun <run-id> --failed
      BASH
      "roll back" => <<~BASH
        gem yank ruact -v X.Y.Z
      BASH
    }
  end

  def markdown_link_targets(markdown)
    Ruact::Spec::MarkdownGate.link_targets(markdown)
  end

  def relative(targets)
    Ruact::Spec::MarkdownGate.relative(targets)
  end

  def bash_blocks(markdown)
    Ruact::Spec::MarkdownGate.bash_blocks(markdown)
  end

  # Every repository variable and secret the document treats as a control,
  # however it spells it — the `gh variable` commands a reader copies and any
  # workflow-expression reference.
  def documented_gates
    (releasing.scan(/gh variable (?:set|delete)(?:\s+-\w+\s+\S+)*\s+([A-Z0-9_]+)/).flatten +
     releasing.scan(/vars\.([A-Z0-9_]+)/).flatten).uniq.sort
  end

  def workflow_gates
    release_condition.scan(/vars\.([A-Z0-9_]+)/).flatten.uniq.sort
  end

  # The comparison, not only the name. `== 'true'` and `!= 'false'` name the
  # same variable and mean opposite things — under the second, an unset
  # variable publishes. The document tells the reader to SET the variable to
  # turn publication on, so the value it writes has to be the value the
  # workflow tests for, and the test has to be an equality.
  def gate_comparison
    release_condition.match(/vars\.[A-Z0-9_]+\s*(==|!=)\s*'([^']*)'/)&.captures
  end

  def documented_gate_value
    releasing[/gh variable set\s+[A-Z0-9_]+\s+-b\s+(\S+)/, 1]
  end

  # Every conjunct of the release job's `if:`, by its left-hand operand. The
  # document explains three things a reader has to know before believing that a
  # merge publishes; a fourth conjunct is a gate they have never been told
  # about.
  def condition_operands
    release_condition.split("&&").filter_map { |clause| clause.strip[/\A[A-Za-z_][\w.]*/] }
  end

  it "exists and has substance" do
    expect(releasing_path).to exist
    expect(releasing.strip.length).to be > 2_000,
                                      "RELEASING.md is #{releasing.strip.length} bytes — too short to " \
                                      "answer what to decide, what CI does, how to verify and how to " \
                                      "roll back."
  end

  it "links only to files that exist in this repository" do
    targets = relative(markdown_link_targets(releasing))
    missing = targets.reject { |target| root.join(target.split("#").first.to_s).exist? }

    expect(targets).not_to be_empty, "expected RELEASING.md to link at least one repo-relative file"
    expect(missing).to be_empty,
                       "RELEASING.md links files that do not exist in this repository: #{missing.inspect}"
  end

  it "names nothing that exists only in the private repository" do
    offenders = Ruact::Spec::MarkdownGate::PRIVATE_SIDE.filter_map do |pattern|
      pattern.source if releasing.match?(pattern)
    end

    expect(offenders).to be_empty,
                         "RELEASING.md names private-side vocabulary (#{offenders.inspect}). It ships " \
                         "inside every published gem; its reader may have nothing but the gem."
  end

  # The strongest anti-rot statement available here, and the reason a later
  # story cannot change the release mechanism quietly: the gate is not a list
  # somebody maintains, it is read out of the workflow. Rename the variable,
  # gate on something else, or drop the gate, and this goes red naming the
  # document as the thing to rewrite.
  it "documents the gate the release job is actually conditioned on" do
    expect(workflow_gates).not_to be_empty,
                                  "the release job's `if:` no longer gates on a repository variable " \
                                  "(#{release_condition.inspect}). The release mechanism changed; " \
                                  "RELEASING.md describes the old one."
    expect(documented_gates).to eq(workflow_gates),
                                "RELEASING.md treats #{documented_gates.inspect} as the release " \
                                "control; .github/workflows/ci.yml gates the release job on " \
                                "#{workflow_gates.inspect}. A document naming a switch that does not " \
                                "exist, or missing the one that does, publishes by surprise."
  end

  # AC5(4)'s other half: the name alone is not the gate. `== 'true'` and
  # `!= 'false'` name the same variable and mean opposite things, and the
  # inversion is a change a later story is expected to make.
  it "turns the gate on in the sense the workflow tests it" do
    operator, value = gate_comparison

    expect(operator).to eq("=="),
                        "the release job tests the gate with #{operator.inspect}, not equality " \
                        "(#{release_condition.inspect}). RELEASING.md describes setting the variable as " \
                        "the way to turn publication ON; under an inverted test, setting it turns " \
                        "publication OFF and an unset variable publishes."
    expect(documented_gate_value).to eq(value),
                                     "RELEASING.md tells the reader to set the gate to " \
                                     "#{documented_gate_value.inspect}; the workflow publishes when it " \
                                     "is #{value.inspect}. Following the document would not publish."
  end

  # And nothing else: a path filter, a tag condition or a second variable is a
  # gate the reader has never been told about, and they would believe a merge
  # publishes when it does not.
  it "is gated on nothing the document does not explain" do
    explained = ["github.event_name", "github.ref", "vars.#{workflow_gates.first}"]

    expect(condition_operands).to match_array(explained),
                                  "the release job is conditioned on " \
                                  "#{condition_operands.inspect}; RELEASING.md explains " \
                                  "#{explained.inspect}. A condition the document does not mention is a " \
                                  "reason a merge silently does not publish."
  end

  # The document says the job waits on every other job in the workflow. That is
  # a claim about a list, so it is read off the list rather than trusted.
  it "waits on every other job, as the document says it does" do
    unwaited = workflow.fetch("jobs").keys - workflow.dig("jobs", "release", "needs") - ["release"]

    expect(unwaited).to be_empty,
                        "the release job does not wait on #{unwaited.inspect}, so those jobs can be red " \
                        "while a release goes out. RELEASING.md tells the reader the opposite — rewrite " \
                        "it, or add them to `needs:`."
  end

  it "documents the branch the release job is actually conditioned on" do
    branch = release_condition[%r{refs/heads/(\S+?)'}, 1]

    expect(branch).not_to be_nil,
                          "the release job's `if:` no longer names a branch (#{release_condition.inspect})."
    expect(releasing).to include("`#{branch}`"),
                         "the release job runs on pushes to #{branch.inspect}, which RELEASING.md never " \
                         "names — so the reader does not know what act publishes."
  end

  it "prescribes no step the release process does not perform" do
    offenders = hand_steps.keys.select do |step|
      step.is_a?(Regexp) ? releasing.match?(step) : releasing.include?(step)
    end
    explanations = offenders.map { |step| "#{step.inspect} — #{hand_steps.fetch(step)}" }

    expect(offenders).to be_empty,
                         "RELEASING.md prescribes steps nobody performs:\n  #{explanations.join("\n  ")}\n" \
                         "Performed by hand and by CI, each of these produces a second version."
  end

  # Story 5.8's lesson, applied before it costs anything: do not replace an
  # ageing claim with another ageing claim — remove the class of claim. A
  # concrete version anywhere in here is false one release later, and this
  # document is republished with every release, so it would be false inside
  # the gem that made it false.
  it "names no concrete version, only the placeholder" do
    literals = releasing.scan(/(?<![\w.])v?\d+\.\d+\.(?:\d+|x)(?![\w.])/).uniq

    expect(literals).to be_empty,
                        "RELEASING.md names concrete versions (#{literals.inspect}). Write X.Y.Z: this " \
                        "file ships inside the gem of every subsequent release."
  end

  it "does not claim a check gates merging, because none of them does" do
    offenders = Ruact::Spec::MarkdownGate::ENFORCEMENT_CLAIMS.filter_map do |pattern|
      pattern.source if releasing.match?(pattern)
    end

    expect(offenders).to be_empty,
                         "RELEASING.md claims a check gates merging (#{offenders.inspect}). This " \
                         "repository's `main` has no branch protection and no rulesets. Say what " \
                         "happens instead: a red job skips the release and the merge still lands."
  end

  # Not "each pinned block appears somewhere" — that is satisfied by one hidden
  # exact copy while the block the reader actually reaches says something else.
  it "pins every bash block a maintainer could copy, in the order they appear" do
    actual = bash_blocks(releasing)
    expected = command_spine.values

    expect(actual.length).to eq(expected.length),
                             "RELEASING.md has #{actual.length} ```bash block(s); this spec pins " \
                             "#{expected.length}. A block a maintainer can copy and this gate does not " \
                             "watch is exactly how the commands drift. Pin it or drop it."

    actual.zip(expected, command_spine.keys).each do |got, want, name|
      expect(got).to eq(want),
                     "the #{name} block in RELEASING.md drifted from the literal this spec pins."
    end
  end

  it "pins the CHANGELOG templates a maintainer copies" do
    expected = [
      <<~MD,
        ## [Unreleased]

        ## [X.Y.Z] - YYYY-MM-DD

        ### Added
        ### Changed
        ### Fixed
        ### Removed
      MD
      <<~MD
        [Unreleased]: https://github.com/luizcg/ruact/compare/vX.Y.Z...HEAD
        [X.Y.Z]: https://github.com/luizcg/ruact/releases/tag/vX.Y.Z
      MD
    ]

    expect(releasing.scan(/^```markdown[ \t]*\n(.*?)^```/m).flatten).to eq(expected),
                                                                        "the stamp templates in " \
                                                                        "RELEASING.md drifted. The " \
                                                                        "compare line is the literal " \
                                                                        "spec/changelog_spec.rb asserts; " \
                                                                        "a maintainer copying a drifted " \
                                                                        "one reddens the suite on the " \
                                                                        "push that was meant to release."
  end

  it "is reachable from both documents that promise it" do
    expect(root.join("README.md").read).to include("[RELEASING.md](RELEASING.md)"),
                                           "README.md does not link RELEASING.md."
    expect(root.join("CONTRIBUTING.md").read).to include("[RELEASING.md](RELEASING.md)"),
                                                 "CONTRIBUTING.md does not link RELEASING.md, and it " \
                                                 "is the document that promises the release process is " \
                                                 "described somewhere else."
  end
end
