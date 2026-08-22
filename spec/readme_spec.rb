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

  # `[text](target)` and `![alt](target)`, inline-title form allowed.
  def markdown_link_targets(markdown)
    markdown.scan(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten
  end

  # A fenced block is a picture OF markup, not markup. Anything inside one is
  # displayed, never rendered, so it must not be mistaken for a real reference.
  def outside_code_fences(markdown)
    markdown.gsub(/^```.*?^```/m, "")
  end

  # Story 5.2 — GitHub's sanitizer allows raw `<img>`, and `width` is the only
  # lever it gives for sizing a README image, so the demo is HTML rather than
  # markdown. The regex above cannot see an HTML attribute, which left the one
  # reference the README most needs checked entirely ungated. This closes that.
  #
  # Returns whole tags, not just `src`: an attribute is only meaningful together
  # with the tag it belongs to. Checking "some `<img>` has the right src" and
  # "the first `<img>` has good alt text" as two independent facts passes a
  # README where those are two different images.
  def img_tags(markdown)
    outside_code_fences(markdown).scan(/<img\b[^>]*?>/m)
  end

  def attr(tag, name)
    tag[/\b#{name}=(?:"([^"]*)"|'([^']*)')/m, 1] || tag[/\b#{name}=(?:"([^"]*)"|'([^']*)')/m, 2]
  end

  def html_img_targets(markdown)
    img_tags(markdown).filter_map { |tag| attr(tag, "src") }
  end

  # The one `<img>` this story owns, found by its src rather than by position.
  def demo_src
    "https://ruact.dev/readme-write-verify.gif"
  end

  def demo_img(markdown)
    img_tags(markdown).find { |tag| attr(tag, "src") == demo_src }
  end

  # Absolute URLs, anchors and mailto: links are somebody else's problem; on-disk
  # targets are ours.
  def relative(targets)
    targets.reject { |target| target.start_with?("http://", "https://", "#", "mailto:") }
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
    targets = relative(markdown_link_targets(readme) + html_img_targets(readme))
    missing = targets.reject { |target| root.join(target.split("#").first.to_s).exist? }

    expect(targets).not_to be_empty, "expected the README to link at least one repo-relative file"
    expect(missing).to be_empty,
                       "README.md links files that do not exist in the gem repository: #{missing.inspect}"
  end

  # Story 5.2 — the demo GIF is a documentation asset hosted with the site, so
  # this repository stays free of binaries: no `.gem` download and no clone
  # pays for it. The consequence is that the reference is an absolute URL, and
  # an absolute URL cannot be resolved on disk here — the monorepo puts it in
  # `website/scripts/verify-urls.mjs`'s PATHS, checked against the deployed
  # site, so a dead image goes red there instead of rotting silently.
  it "carries the write→verify demo, hosted with the site rather than committed here" do
    expect(demo_img(readme)).not_to be_nil,
                                    "no <img> in README.md points at #{demo_src}"

    # `git ls-files` and not a filesystem glob, because that is precisely what
    # `spec.files` packages (ruact.gemspec) — untracked build output is not the
    # question here, and coverage/ is full of it.
    tracked = IO.popen(%w[git ls-files -z], chdir: root.to_s, err: IO::NULL) do |ls|
      ls.readlines("\x0", chomp: true)
    end
    committed_media = tracked.grep(/\.(gif|mp4|webm|webp)\z/i)

    expect(committed_media).to be_empty,
                               "media committed under gem/ ships inside every `.gem` and stays in the " \
                               "clone history forever: #{committed_media.inspect}"
  end

  # The alt text is the only thing a screen-reader user — or an agent reading
  # the README as text — gets. "demo" is not a description.
  it "describes the demo's arc in its alt text" do
    # Read off the demo's OWN tag. Reading the first `<img>` in the file would
    # let a second image satisfy this while the demo shipped `alt="demo"`.
    tag = demo_img(readme)

    expect(tag).not_to be_nil, "no <img> in README.md points at #{demo_src}"

    alt = attr(tag, "alt").to_s

    expect(alt.split.length).to be > 40, "the demo's alt text does not describe the arc: #{alt.inspect}"
    expect(alt).to include("Ruact::ChildrenNotSupportedError")
    expect(alt).not_to match(/\bbuild\b/i),
                       "the failure the demo shows happens server-side at render, not at build — " \
                       "see Story 5.2 AC4"
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
