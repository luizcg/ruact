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
# So the claims that can be derived are derived, from artifacts that cannot
# drift independently of what they describe: the workflow for the trigger and
# the gate, this repository's own files for the links. The rest are absences —
# a step nobody performs, a version literal, a merge-gate claim — which is the
# weaker kind of statement and is used only where there is nothing to derive
# from.
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
  let(:release_condition) { release_job.to_h["if"].to_s.sub(/\A\s*\$\{\{/, "").sub(/\}\}\s*\z/, "") }

  # Steps this process does not perform, mapped to what performs them instead.
  # Every one of these was a numbered instruction in the file this replaced.
  let(:hand_steps) do
    {
      "npm publish" => "nothing is published to npm — the Vite plugin ships inside the gem",
      "npm unpublish" => "there is nothing on npm to roll back",
      "gem build" => "the release job builds the gem",
      "gem push" => "the release job uploads it, over OIDC, with no interactive step",
      "gem signin" => "there is no interactive credential to sign in with",
      "release/v" => "a release is a pull request like any other; nothing branches on a naming convention"
    }
  end

  # The mirror of `hand_steps`, and the half that changed in Story 5.10. The
  # version used to have exactly one writer and it was the workflow, so telling
  # the reader to write it was the error. It is now written in the pull request,
  # so NOT telling them is — and a document that omits the one step a human
  # performs is unfollowable in a way no amount of accurate prose elsewhere
  # repairs.
  let(:owned_steps) do
    {
      "lib/ruact/version.rb" => "the version is written in the pull request; the reader has to be told where",
      "bin/release" => "the preparation is executable, and the checklist is the pull-request body it generates",
      "CHANGELOG.md" => "the record moves in the same pull request as the version"
    }
  end

  # The command spine, byte for byte. A drifted block here costs a version
  # nobody asked for, or a stop that does not stop.
  let(:command_spine) do
    {
      "prepare the release" => <<~BASH,
        bin/release X.Y.Z
      BASH
      "verify" => <<~BASH,
        curl -s https://rubygems.org/api/v1/versions/ruact/latest.json
      BASH
      "find the run that should have released" => <<~BASH,
        gh run list --branch main -L 3
        gh run rerun <run-id> --failed
      BASH
      "halt" => <<~BASH,
        gh variable set RUACT_RELEASE_HALT -b stop -R luizcg/ruact
      BASH
      "resume" => <<~BASH,
        gh variable delete RUACT_RELEASE_HALT -R luizcg/ruact
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

  # Every repository variable the release job READS, wherever it reads it —
  # from the `if:`, and from the `env:` bindings of its steps. The `if:` is
  # deliberately not the only place any more: a variable there produces a
  # `skipped` job, which says nothing, so the stop moved into a step.
  #
  # Structured rather than a scan of the whole dumped job, and that is the
  # point: a `vars.` reference inside a `run:` block is a shell comment at
  # least as often as it is a wiring, so a scan would keep passing on the
  # comment left behind by the binding it lost.
  def workflow_gates
    ([release_condition] + step_environments).join("\n").scan(/vars\.([A-Z0-9_]+)/).flatten.uniq.sort
  end

  def step_environments
    release_steps.flat_map { |step| step.to_h.fetch("env", {}).values.map(&:to_s) }
  end

  # And the variables in the `if:` alone, which is a different question: those
  # are the ones that can silently skip the job.
  def condition_gates
    release_condition.scan(/vars\.([A-Z0-9_]+)/).flatten.uniq.sort
  end

  def release_job
    workflow.dig("jobs", "release")
  end

  def release_steps
    Array(release_job.to_h["steps"])
  end

  # The step that reads the stop, identified by its `env:` binding.
  def halt_step
    release_steps.find { |step| step.to_h.fetch("env", {}).any? { |_, v| v.to_s.match?(/vars\.[A-Z0-9_]+/) } }
  end

  # `[shell name, workflow expression]` — the two halves whose agreement is
  # what makes the stop real. Neither alone proves anything: a binding nothing
  # tests is dead, and a test of a name nothing binds is always false.
  def halt_binding
    halt_step.to_h.fetch("env", {}).find { |_, value| value.to_s.match?(/vars\.[A-Z0-9_]+/) } || [nil, nil]
  end

  # Every conjunct of the release job's `if:`, by its left-hand operand. The
  # document explains what a reader has to know before believing that a merge
  # publishes; a further conjunct is a gate they have never been told about.
  def condition_operands
    release_condition.split("&&").map { |clause| clause.strip[/\A[A-Za-z_][\w.]*/] || clause.strip }
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
  # story cannot change the release mechanism quietly: the stop is not a list
  # somebody maintains, it is read out of the workflow. Rename the variable,
  # stop on something else, or drop it, and this goes red naming the document as
  # the thing to rewrite.
  it "documents the emergency stop the release job actually reads" do
    expect(workflow_gates).not_to be_empty,
                                  "the release job no longer reads a repository variable anywhere. " \
                                  "The release mechanism changed; RELEASING.md describes the old one."
    expect(documented_gates).to eq(workflow_gates),
                                "RELEASING.md treats #{documented_gates.inspect} as the release " \
                                "control; .github/workflows/ci.yml reads #{workflow_gates.inspect}. A " \
                                "document naming a switch that does not exist, or missing the one that " \
                                "does, publishes by surprise."
  end

  # Half the polarity: whatever the stop is, it must not be able to SKIP the
  # job. A variable in the `if:` produces a `skipped` job, which is
  # indistinguishable from a merge that had nothing to publish — and a stop
  # nobody can tell from ordinary quiet is the failure this design exists to
  # remove.
  it "does not let the stop skip the job" do
    expect(condition_gates).to be_empty,
                               "the release job's `if:` gates on #{condition_gates.inspect}, so a set " \
                               "variable would make the job `skipped` rather than red."
  end

  # The other half, and it is asserted through the WIRING rather than through
  # any mention of the variable: the workflow expression is bound to a shell
  # name, that name is tested for NON-emptiness (so unset publishes), the test
  # exits non-zero (so a forgotten stop reddens `main`), and it runs only once
  # a publish has been decided (so it names a version it actually refused).
  it "stops loudly, on a version it was about to publish" do
    name, expression = halt_binding
    run = halt_step.to_h["run"].to_s

    expect(expression).to match(/\A\$\{\{\s*vars\.[A-Z0-9_]+\s*\}\}\s*\z/),
                          "no step binds a repository variable into its environment (#{expression.inspect})."
    expect(run).to match(/-n\s+"?\$\{?#{Regexp.escape(name.to_s)}\b/),
                   "the step does not test #{name.inspect} for non-emptiness, so it is not true that " \
                   "leaving the variable unset publishes."
    expect(run).to include("exit 1"),
                   "the stop does not fail the run. A stop that ends green is a stop nobody notices they " \
                   "left in place."
    expect(halt_step.to_h["if"].to_s).to match(/steps\.\w+\.outputs\.\w+/),
                                         "the stop is not conditioned on the publish decision, so it " \
                                         "cannot name the version it refused."
  end

  # AC2's invariant, and the reason `main` can be protected at all: the job
  # writes a tag and nothing else. A commit pushed to `main` by the workflow
  # would be a second writer for the version, would land after the checks that
  # were supposed to see it, and would need a bypass on the branch it pushes to.
  it "pushes no commit to main, only a tag" do
    job = YAML.dump(release_job)

    expect(job).not_to match(/git commit/),
                       "the release job commits. The version is written in the pull request now; a " \
                       "second writer is the defect, not the mechanism."
    expect(job).not_to match(/skip ci/),
                       "the release job pushes a commit that skips CI, so the tip of `main` would be " \
                       "code no check has seen."
    expect(job).not_to match(/git push origin HEAD/),
                       "the release job pushes a commit to `main`."
  end

  # And nothing else: a path filter, a tag condition or a second variable is a
  # And nothing else: a path filter, a tag condition or a second variable is a
  # gate the reader has never been told about, and they would believe a merge
  # publishes when it does not.
  it "is gated on nothing the document does not explain" do
    explained = ["github.event_name", "github.ref", *condition_gates.map { |name| "vars.#{name}" }]

    expect(condition_operands).to match_array(explained),
                                  "the release job is conditioned on " \
                                  "#{condition_operands.inspect}; RELEASING.md explains " \
                                  "#{explained.inspect}. A condition the document does not mention is a " \
                                  "reason a merge silently does not publish."
  end

  # An invariant of the workflow, not of the document: nothing here reads
  # RELEASING.md. It sits in this file because the document's description of
  # the gate is only true while this holds.
  it "waits on every other job" do
    needs = Array(workflow.dig("jobs", "release", "needs"))
    unwaited = workflow.fetch("jobs").keys - needs - ["release"]

    expect(unwaited).to be_empty,
                        "the release job does not wait on #{unwaited.inspect}, so those jobs can be red " \
                        "while a release goes out."
  end

  it "documents the branch the release job is actually conditioned on" do
    branch = release_condition[%r{refs/heads/(\S+?)'}, 1]

    expect(branch).not_to be_nil,
                          "the release job's `if:` no longer names a branch (#{release_condition.inspect})."
    expect(releasing).to include("push to `#{branch}`"),
                         "the release job runs on pushes to #{branch.inspect}, and RELEASING.md never " \
                         "says so in those words. Naming the branch somewhere in the file is not enough — " \
                         "this one spans `release` five times as the job's name — so what is asserted is " \
                         "the sentence the reader acts on: \"push to `#{branch}`\"."
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
  it "names the steps the release process leaves to a person" do
    missing = owned_steps.keys.reject { |step| releasing.include?(step) }
    explanations = missing.map { |step| "#{step.inspect} — #{owned_steps.fetch(step)}" }

    expect(missing).to be_empty,
                       "RELEASING.md never names:\n  #{explanations.join("\n  ")}\n" \
                       "A release document that omits the steps only a person performs cannot be followed."
  end

  it "names no concrete version, only the placeholder" do
    literals = releasing.scan(/(?<![\w.])v?\d+\.\d+\.(?:\d+|x)\b/).uniq

    expect(literals).to be_empty,
                        "RELEASING.md names concrete versions (#{literals.inspect}). Write X.Y.Z: this " \
                        "file ships inside the gem of every subsequent release."
  end

  # Not because the claim is false — what merges and what does not is a
  # repository setting, and this suite takes no network, so it could not tell
  # you either way. Because it is UNVERIFIABLE from in here, and Story 5.8's
  # lesson is that an ageing claim is not repaired by a fresher ageing claim.
  # The document says what the checks do; what they decide is not its sentence
  # to write.
  it "makes no claim about what gates merging" do
    offenders = Ruact::Spec::MarkdownGate::ENFORCEMENT_CLAIMS.filter_map do |pattern|
      pattern.source if releasing.match?(pattern)
    end

    expect(offenders).to be_empty,
                         "RELEASING.md states what a check decides at merge time (#{offenders.inspect}). " \
                         "Nothing in this repository can verify that, so it is a claim that rots " \
                         "silently. Say what happens instead."
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

  it "is reachable from both documents that promise it" do
    expect(root.join("README.md").read).to include("[RELEASING.md](RELEASING.md)"),
                                           "README.md does not link RELEASING.md."
    expect(root.join("CONTRIBUTING.md").read).to include("[RELEASING.md](RELEASING.md)"),
                                                 "CONTRIBUTING.md does not link RELEASING.md, and it " \
                                                 "is the document that promises the release process is " \
                                                 "described somewhere else."
  end
end
