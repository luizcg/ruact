# frozen_string_literal: true

require "spec_helper"
require "date"
require "pathname"

# Story 5.9 — the changelog gate.
#
# `CHANGELOG.md` is the release record, it is packaged inside every published
# `.gem`, and it is the source the documentation site's changelog page is
# generated from — verbatim, with no sanitising in between.
#
# It had never been checked, and the reason a check is worth having is that the
# damage arrives through ordinary edits: stamping a release is an edit, and
# un-stamping one that was called off is another. Edits leave seams, and a seam
# in this file is invisible in a diff and permanent in a published gem.
#
# The claims here are structural — the file against itself, and against
# `Ruact::VERSION`. That is deliberate: the prose is history, and history is not
# checkable.
#
# WHAT IT DOES NOT PROMISE
#
#   That an entry is accurate, complete, or written for anybody in particular.
#
#   Nor that a fenced code block is well-formed. Fences are stripped before the
#   structure is parsed, so an entry may *show* a changelog heading as an
#   example without that example being read as a release. The private-path
#   check is the deliberate exception: it reads the whole file, because a path
#   shipped inside a code span is still shipped.
RSpec.describe "CHANGELOG.md", :story_5_9 do
  subject(:changelog) { changelog_path.read }

  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }
  let(:changelog_path) { root.join("CHANGELOG.md") }

  # `## [label]` with the optional ` - date` the released headings carry.
  def heading_pattern
    /^##\s+\[([^\]]+)\](?:\s+-\s+(\S+))?\s*$/
  end

  # Fenced blocks are illustrations. A release entry may quote the shape of a
  # changelog — this file's own stamp instructions live next door in
  # RELEASING.md — and quoting it must not conjure a release. One recogniser,
  # shared with the specs that read the same files for other reasons.
  def prose
    Ruact::Spec::MarkdownGate.prose(changelog)
  end

  def headings
    prose.each_line.filter_map do |line|
      match = line.match(heading_pattern)
      { label: match[1], date: match[2] } if match
    end
  end

  def version_headings
    headings.select { |heading| heading[:label].match?(/\A\d+\.\d+\.\d+\z/) }
  end

  def versions
    version_headings.map { |heading| heading[:label] }
  end

  # Lines that open a bracketed section without the shape the rest of the file
  # uses. Nothing else here sees them — `headings` cannot parse them — and that
  # is why they are collected separately: a heading no recogniser recognises is
  # a heading nothing checks, and it would pass every example below by being
  # absent from all of them.
  def malformed_headings
    prose.each_line.filter_map do |line|
      next unless line.start_with?("## [")

      line.strip unless line.match?(heading_pattern)
    end
  end

  # `[label]: url` at the bottom of the file.
  def link_refs
    prose.scan(/^\[([^\]]+)\]:\s+\S+/).flatten
  end

  # A reference whose label is a release is claiming to resolve a heading. Any
  # other label is an ordinary reference-style link and is none of this gate's
  # business.
  def release_link_refs
    link_refs.select { |label| label == "Unreleased" || label.match?(/\A\d+\.\d+\.\d+\z/) }
  end

  # `[label]: target`, as pairs.
  def link_ref_targets
    prose.scan(/^\[([^\]]+)\]:\s+(\S+)/).to_h
  end

  # The `###` sections inside each `##` block, as pairs rather than a Hash:
  # keying on the heading text would let a duplicated block overwrite the one
  # before it and take its sections out of scope — which is exactly the damage
  # the duplicate-section example exists to find.
  def sections_by_block
    prose.split(/^(?=##\s)/).select { |block| block.start_with?("## ") }.map do |block|
      [block.lines.first.sub(/\A##\s+/, "").strip, block.scan(/^###\s+(.+?)\s*$/).flatten]
    end
  end

  def semver(version)
    version.split(".").map(&:to_i)
  end

  # Equality, with no window either side. The file used to be allowed to run one
  # release ahead of the code, because the heading was stamped by a person and
  # the number was computed by CI afterwards — so between the two there was a
  # commit where they legitimately disagreed. Both are now written in the same
  # pull request, by the same hand, so any disagreement at all is a mistake, and
  # the shape of the mistake no longer matters enough to enumerate.
  it "is stamped for exactly the version this gem currently is" do
    expect(versions.first).to eq(Ruact::VERSION),
                              "CHANGELOG.md's newest heading is #{versions.first.inspect} and " \
                              "lib/ruact/version.rb says #{Ruact::VERSION}. They move together, in one " \
                              "pull request — `bin/release X.Y.Z` writes both. Whichever moved without " \
                              "the other, the release is half-recorded."
  end

  it "gives every released heading a link reference, and every release reference a heading" do
    labels = headings.map { |heading| heading[:label] }
    orphan_headings = labels - link_refs
    orphan_refs = release_link_refs - labels

    expect(orphan_headings).to be_empty,
                               "CHANGELOG.md headings with no link reference: #{orphan_headings.inspect}. " \
                               "A heading with no reference renders as literal brackets and points at " \
                               "nothing — which is also what a version that was never released looks like."
    expect(orphan_refs).to be_empty,
                           "CHANGELOG.md link references with no heading: #{orphan_refs.inspect}."
  end

  # A repeated heading or a repeated reference is the mirror of the seam above:
  # both are invisible to a set difference, and the second definition of a
  # reference is the one Markdown throws away.
  it "says each release exactly once" do
    repeated_headings = headings.map { |heading| heading[:label] }.tally.select { |_, count| count > 1 }.keys
    repeated_refs = link_refs.tally.select { |_, count| count > 1 }.keys

    expect(repeated_headings).to be_empty,
                                 "CHANGELOG.md has more than one heading for #{repeated_headings.inspect}."
    expect(repeated_refs).to be_empty,
                             "CHANGELOG.md defines #{repeated_refs.inspect} more than once. Markdown " \
                             "resolves the first and discards the rest, so the link a reader follows is " \
                             "not necessarily the one that was edited last."
  end

  it "keeps an Unreleased section" do
    labels = headings.map { |heading| heading[:label] }

    expect(labels).to include("Unreleased"),
                      "CHANGELOG.md has no [Unreleased] section, so there is nowhere for the next change " \
                      "to accumulate."
  end

  it "dates every release heading in ISO form" do
    undated = version_headings.reject do |heading|
      date = heading[:date].to_s
      next false unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      begin
        Date.iso8601(date)
      rescue ArgumentError, TypeError
        false
      end
    end

    expect(malformed_headings).to be_empty,
                                  "CHANGELOG.md has bracketed headings this file's own shape does not " \
                                  "cover: #{malformed_headings.inspect}"
    expect(undated).to be_empty,
                       "CHANGELOG.md headings are not `## [X.Y.Z] - YYYY-MM-DD`: " \
                       "#{undated.map { |h| "#{h[:label]} #{h[:date].inspect}" }.inspect}"
  end

  it "lists releases newest first" do
    sorted = versions.sort_by { |version| semver(version) }.reverse

    expect(versions).to eq(sorted),
                        "CHANGELOG.md release headings are out of order: #{versions.inspect}. Expected " \
                        "#{sorted.inspect}. A version below an older one is usually a version that was " \
                        "never released."
  end

  it "opens each section once per version block" do
    offenders = sections_by_block.filter_map do |label, sections|
      duplicates = sections.tally.select { |_, count| count > 1 }.keys
      "[#{label}]: #{duplicates.inspect}" unless duplicates.empty?
    end

    expect(offenders).to be_empty,
                         "CHANGELOG.md opens the same section twice inside one version block " \
                         "(#{offenders.inspect}). Merge them, keeping every bullet. This is the seam an " \
                         "un-stamped release leaves behind: content moves back into [Unreleased] beside " \
                         "a section that is already there."
  end

  # Three readers see this file from three different places: the repository
  # page, a `.gem` unpacked on somebody's disk, and a generated page on the
  # documentation site. No relative target resolves in all three — one that
  # works here 404s there — so the only link that is not a trap is an absolute
  # one. This is total rather than a resolves-on-disk check, because a
  # resolves-on-disk check is what would have passed the link that broke the
  # site build.
  it "points every release reference at that release's tag" do
    misdirected = link_ref_targets.slice(*release_link_refs).filter_map do |label, target|
      expected = label == "Unreleased" ? "compare/v#{versions.first}...HEAD" : "releases/tag/v#{label}"
      "[#{label}] → #{target}" unless target.end_with?(expected)
    end

    expect(misdirected).to be_empty,
                           "CHANGELOG.md release references point somewhere other than their own release " \
                           "(#{misdirected.inspect}). A reference whose label and target disagree is the " \
                           "re-stamp seam: the heading is right, the link is a release old, and both halves " \
                           "look fine on their own."
  end

  it "closes every fence it opens" do
    open = Ruact::Spec::MarkdownGate.fences_left_open(changelog)

    expect(open).to be_empty,
                    "CHANGELOG.md leaves a fenced block open at line " \
                    "#{open.map { |region| region[:first] + 1 }.inspect}. Everything after it reads as " \
                    "code, so headings, links and sections below are invisible to every check here."
  end

  it "carries no relative link, because its readers are not all in this repository" do
    targets = Ruact::Spec::MarkdownGate.relative(
      Ruact::Spec::MarkdownGate.link_targets(prose) + link_ref_targets.values
    )

    expect(targets).to be_empty,
                       "CHANGELOG.md links relative targets (#{targets.uniq.first(3).inspect}, " \
                       "#{targets.length} in total). Whatever they resolve to here, they do not resolve " \
                       "for a reader who unpacked the gem or who is on ruact.dev, where this file is " \
                       "republished verbatim. Use an absolute URL, or name the file without linking it."
  end

  # Stripping the target is the treatment this file's private links got. The
  # path can come back as prose or as a code span, which no link check sees.
  it "does not name the private side at all" do
    offenders = Ruact::Spec::MarkdownGate::PRIVATE_SIDE.filter_map do |pattern|
      pattern.source if changelog.match?(pattern)
    end

    expect(offenders).to be_empty,
                         "CHANGELOG.md names a private-side path (#{offenders.inspect}). Whether it is a " \
                         "link or plain text, it ships inside every published gem and onto the " \
                         "documentation site, where nobody can open it."
  end
end
