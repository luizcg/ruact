# frozen_string_literal: true

require "spec_helper"
require "pathname"

# Story 5.9 — the changelog gate.
#
# `CHANGELOG.md` is the release record, it is packaged inside every published
# `.gem`, and it is the source the documentation site's changelog page is
# generated from. Three readers, one file, and until now nothing checked it.
#
# What went wrong without a check is what this asserts against: a heading for a
# version that was never released, links whose targets exist only in a
# repository the reader cannot open, and — from a release that was prepared and
# then called off — a second `### Added` inside one version block, because
# un-stamping is an edit and edits leave seams.
#
# The claims are structural: they compare the file against itself and against
# `Ruact::VERSION`. That is deliberate, and it is the only kind of claim that
# survives, because the file's prose is history and history is not checkable.
#
# WHAT IT DOES NOT PROMISE
#
#   That an entry is accurate, complete, or written for anybody in particular.
#   Only that the record's shape holds: the current release is in it, every
#   heading is reachable, the order is the order of releases, and nothing in it
#   points somewhere the reader cannot go.
RSpec.describe "CHANGELOG.md", :story_5_9 do
  subject(:changelog) { changelog_path.read }

  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }
  let(:changelog_path) { root.join("CHANGELOG.md") }

  # `## [label]` with the optional ` - date` the released headings carry.
  def heading_pattern
    /^##\s+\[([^\]]+)\](?:\s+-\s+(\S+))?\s*$/
  end

  # `## [X.Y.Z] - YYYY-MM-DD` and `## [Unreleased]`. A `##` heading that is not
  # bracketed is prose, not a release, and is out of scope by construction —
  # which is how a non-version section is allowed to exist at all.
  def headings
    changelog.each_line.with_index(1).filter_map do |line, number|
      match = line.match(heading_pattern)
      { label: match[1], date: match[2], line: number } if match
    end
  end

  def version_headings
    headings.select { |heading| heading[:label].match?(/\A\d+\.\d+\.\d+\z/) }
  end

  # Lines that open a bracketed section without the shape the rest of the file
  # uses. Nothing else here sees them — `headings` cannot parse them — and that
  # is why they are collected separately: a heading no recogniser recognises is
  # a heading nothing checks, and it would pass every example below by being
  # absent from all of them.
  def malformed_headings
    changelog.each_line.with_index(1).filter_map do |line, number|
      next unless line.start_with?("## [")

      { label: line.strip, date: nil, line: number } unless line.match?(heading_pattern)
    end
  end

  # `[label]: url` at the bottom of the file.
  def link_refs
    changelog.scan(/^\[([^\]]+)\]:\s+\S+/).flatten
  end

  # The `###` sections inside each `##` block, block by block. Splitting on
  # every `##` and not only the bracketed ones matters: a section that is
  # deliberately not a version heading still ends the block above it, and a
  # split that ignores it silently attributes its sections to the last release.
  def sections_by_block
    blocks = changelog.split(/^(?=##\s)/).drop(1)

    blocks.to_h do |block|
      [block.lines.first.sub(/\A##\s+/, "").strip, block.scan(/^###\s+(.+?)\s*$/).flatten]
    end
  end

  def semver(version)
    version.split(".").map(&:to_i)
  end

  it "has a heading for the version this gem currently is" do
    labels = version_headings.map { |heading| heading[:label] }

    expect(labels).to include(Ruact::VERSION),
                      "lib/ruact/version.rb says #{Ruact::VERSION}, and CHANGELOG.md has no heading for " \
                      "it (#{labels.first(3).inspect}…). Either the release was published without its " \
                      "entry, or the entry was stamped with a version the release job did not produce — " \
                      "which is what happens when a merge carries the minor marker and the heading " \
                      "predicted a patch."
  end

  it "gives every released heading a link reference, and every link reference a heading" do
    labelled = headings.map { |heading| heading[:label] }
    orphan_headings = labelled - link_refs
    orphan_refs = link_refs - labelled

    expect(orphan_headings).to be_empty,
                               "CHANGELOG.md headings with no link reference: #{orphan_headings.inspect}. " \
                               "A heading with no reference renders as literal brackets and points at " \
                               "nothing — which is also what a version that was never released looks like."
    expect(orphan_refs).to be_empty,
                           "CHANGELOG.md link references with no heading: #{orphan_refs.inspect}."
  end

  it "keeps an Unreleased section pointed at the current version" do
    labels = headings.map { |heading| heading[:label] }

    expect(labels).to include("Unreleased"),
                      "CHANGELOG.md has no [Unreleased] section, so there is nowhere for the next change " \
                      "to accumulate."
    expect(changelog).to include("[Unreleased]: https://github.com/luizcg/ruact/compare/v#{Ruact::VERSION}...HEAD"),
                         "[Unreleased]'s compare link does not start at v#{Ruact::VERSION}, so it either " \
                         "hides changes that are already released or claims released ones are not."
  end

  it "dates every release heading in ISO form" do
    undated = version_headings.reject { |heading| heading[:date]&.match?(/\A\d{4}-\d{2}-\d{2}\z/) }

    expect(malformed_headings).to be_empty,
                                  "CHANGELOG.md has bracketed headings this file's own shape does not " \
                                  "cover: #{malformed_headings.map { |h| "line #{h[:line]}: #{h[:label]}" }.inspect}"
    expect(undated).to be_empty,
                       "CHANGELOG.md headings are not `## [X.Y.Z] - YYYY-MM-DD`: " \
                       "#{undated.map { |h| "line #{h[:line]}: #{h[:label]} #{h[:date].inspect}" }.inspect}"
  end

  it "lists releases newest first" do
    versions = version_headings.map { |heading| heading[:label] }
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

  it "links nothing the reader cannot reach" do
    targets = Ruact::Spec::MarkdownGate.relative(Ruact::Spec::MarkdownGate.link_targets(changelog))
    escaping = targets.select { |target| target.start_with?("../") }
    missing = (targets - escaping).reject { |target| root.join(target.split("#").first.to_s).exist? }

    expect(escaping).to be_empty,
                        "CHANGELOG.md links out of this repository (#{escaping.uniq.first(3).inspect}, " \
                        "#{escaping.length} in total). This file is packaged inside every published gem " \
                        "and mirrored onto the documentation site; a target that resolves only in a " \
                        "checkout the reader does not have is a dead link everywhere it is read. Keep " \
                        "the label, drop the target — or link something a stranger can open."
    expect(missing).to be_empty,
                       "CHANGELOG.md links files that do not exist in this repository: #{missing.inspect}"
  end
end
