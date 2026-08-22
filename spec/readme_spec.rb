# frozen_string_literal: true

require "spec_helper"
require "nokogiri"
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

  # Story 5.2 — the demo reference, pinned BYTE FOR BYTE.
  #
  # The first version of this gate hand-rolled HTML and CommonMark recognition
  # out of regexes, and review corrected it in three consecutive rounds:
  # `\bsrc=` matched `data-src=`, a literal `>` inside an attribute ended the
  # tag early, fences were only recognised at column 0, then unterminated
  # fences were not recognised at all, then unquoted attribute values were
  # invisible. Those are not five bugs. Neither HTML nor CommonMark is a
  # regular language, so that list has no end, and a gate whose coverage is
  # "whatever the regex happens to know this week" is not a gate.
  #
  # Replaced by three statements that are TOTAL:
  #
  #   1. the reference is pinned literally — the same move `expected_quick_start`
  #      above already makes for the quick start;
  #   2. the file is allowed EXACTLY ONE raw `<img>`, counted at the byte level;
  #      and
  #   3. the parsed document holds exactly one LIVE `<img>` element, equal to
  #      the pinned one attribute for attribute.
  #
  # (1) and (2) together say something the old scanner could only approximate:
  # every raw image reference in this README is the pinned one. A second `<img>`
  # anywhere — including inside a fenced example, terminated or not — turns
  # this red and has to be gated deliberately rather than slipping through a
  # blind spot. (3) says the thing bytes cannot: that it renders. The pinned
  # block wrapped in an HTML comment satisfies (1) and (2) and shows nothing.
  #
  # Attributes are then read with Nokogiri, already a runtime dependency of this
  # gem (see the gemspec), so unquoted values, `>` inside a value and `data-src`
  # are PARSED rather than pattern-matched. What that scope does and does not
  # promise is written down in the monorepo's gate inventory,
  # docs/examples/getting-started/README.md § "What is still outside both gates".
  def expected_demo_img
    <<~HTML
      <img src="https://ruact.dev/readme-write-verify.gif" width="800"
           alt="An ERB template holding a &lt;LikeButton likes=&#123;@likes&#125; /&gt; tag, and the &quot;use client&quot; React component that tag resolves to. The component renders in a browser and its count changes when it is clicked. Children are then put inside the tag — the JSX habit — and the next request stops server-side with Ruact::ChildrenNotSupportedError, which names the component, the template file and line, and the fix. The children come out again and the page renders." />
    HTML
  end

  def demo_src
    "https://ruact.dev/readme-write-verify.gif"
  end

  # Parsed from the pinned literal, exactly as `expected_quick_start` is the
  # authority for the quick start: one example asserts the README contains
  # these bytes, and the rest read meaning off them. The chain is
  # README -> literal -> parser, and the first link is what makes it honest.
  def demo_node
    Nokogiri::HTML5.fragment(expected_demo_img).at_css("img")
  end

  # Byte-level and case-insensitive on purpose: no parser, no markdown, nothing
  # to have a blind spot. `<IMG`, `<img\n`, an `<img` inside a fence — all count.
  def raw_img_count(markdown)
    markdown.scan(/<img\b/i).length
  end

  # …and the same parser turned on the README ITSELF, because the two byte-level
  # facts above are about bytes, not about rendering: wrap the pinned block in
  # an HTML comment and the literal is still present and the raw count is still
  # one, while GitHub shows nothing at all (verified — `include`=true, raw=1,
  # live nodes=0). Nokogiri is what decides whether a tag is an element or a
  # comment, so it is what the "it renders" half of this gate has to ask.
  def readme_img_nodes
    Nokogiri::HTML5.fragment(readme).css("img")
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
    targets = relative(markdown_link_targets(readme) + [demo_node["src"]])
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
  it "carries the write→verify demo reference, byte for byte" do
    expect(readme).to include(expected_demo_img),
                      "the demo reference in README.md drifted from the literal this spec pins. " \
                      "Change both or neither — and if the recording itself changed, see " \
                      "readme_demo_message_spec.rb."
  end

  # The other half of the pin: because there is exactly ONE raw `<img>` and the
  # example above proves it is the pinned one, "the pinned literal is present"
  # and "every raw image in this file is checked" are the same statement.
  it "carries exactly one raw <img>, so the pin covers every raw image in the file" do
    expect(raw_img_count(readme)).to eq(1),
                                     "README.md has #{raw_img_count(readme)} raw <img> tags. This gate is " \
                                     "written for exactly one — the demo, pinned literally. A second image " \
                                     "must be gated deliberately, not left to a scanner's blind spots."
  end

  # And the demo is LIVE, not merely present. Bytes inside an HTML comment
  # satisfy both statements above and render nothing; only a parser can tell
  # the difference, so the README itself is parsed and the node it yields must
  # be the pinned one, attribute for attribute.
  it "renders the demo as a real element, not as bytes inside a comment" do
    nodes = readme_img_nodes

    expect(nodes.length).to eq(1),
                            "README.md parses to #{nodes.length} live <img> element(s); the demo must be " \
                            "exactly one, and must not be commented out."
    expect(nodes.first.attributes.transform_values(&:value))
      .to eq(demo_node.attributes.transform_values(&:value))
  end

  it "keeps the demo hosted with the site rather than committed here" do
    expect(demo_node["src"]).to eq(demo_src)

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
    # Nokogiri resolves the entities, so this reads what a screen reader reads:
    # `&lt;LikeButton` is the tag the demo shows, not four literal characters.
    alt = demo_node["alt"].to_s

    expect(alt.split.length).to be > 40, "the demo's alt text does not describe the arc: #{alt.inspect}"
    expect(alt).to include("Ruact::ChildrenNotSupportedError")
    expect(alt).not_to match(/\bbuild\b/i),
                       "the failure the demo shows happens server-side at render, not at build — " \
                       "see Story 5.2 AC4"
  end

  # Story 5.2, learned the expensive way: YARD parses README.md as the docs'
  # main file and read `{@likes}` in the demo's alt text as a link macro it
  # could not resolve — and `--fail-on-warning` turned that into a red REQUIRED
  # check, for a README edit, in a job whose output says nothing about READMEs.
  # Braces belong in prose as `&#123;`/`&#125;`: GitHub renders them, YARD never
  # sees them.
  #
  # SCOPE, deliberately: this checks the pinned demo block, not the whole file.
  # Knowing which parts of a markdown document YARD linkifies means knowing
  # where the fenced blocks are, and this gate no longer recognises fences —
  # that is the trade this redesign makes. `yard --fail-on-warning` in this
  # repository's own CI is the TOTAL gate; this example exists so the one line
  # that actually tripped it fails locally, in the suite that owns the README,
  # naming the cause.
  it "keeps YARD link macros out of the demo block, which is what reddened the docs job" do
    # `{@ivar}`, `{Class}`, `{Class::Nested}`, `{Class#method}`, `{Class.method}`
    # — the shapes YARD resolves. It does not try to resolve anything with a
    # space in it, which is why the prose's `{ post: … }` elsewhere is safe.
    macros = expected_demo_img.scan(/\{(?:@\w+|[A-Z][\w:.#]*)\}/)

    expect(macros).to be_empty,
                      "the demo block contains #{macros.inspect}, which YARD tries to resolve as a " \
                      "link and `yard --fail-on-warning` fails on. Use &#123; / &#125;."
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
