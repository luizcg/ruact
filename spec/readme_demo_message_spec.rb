# frozen_string_literal: true

require "spec_helper"
require "pathname"

# Story 5.2 — the anti-rot gate for the README's write→verify demo.
#
# ⚠️  THE README DEMO SHOWS THIS MESSAGE. If this spec goes red, the recording
#     at https://ruact.dev/readme-write-verify.gif is now showing a message the
#     gem no longer produces — RE-RECORD IT.
#     Sources: design-artifacts/E-Assets/readme-write-verify/ in the planning
#     repository (`./build-app.sh && ./record.sh && ./assemble.sh`).
#
# The fixture is PRODUCED BY THE GEM, never transcribed. It was written by
# running the preprocessor over the committed `.html.erb` beside it:
#
#   ruby -Ilib -rruact -e 'begin
#     Ruact::ErbPreprocessor.transform(
#       File.read("spec/fixtures/readme/children-error.html.erb"),
#       identifier: "app/views/home/index.html.erb")
#   rescue Ruact::ChildrenNotSupportedError => e
#     File.write("spec/fixtures/readme/children-error.txt", e.message + "\n")
#   end'
#
# The identifier is the guide's own template path, so the fixture is verbatim
# the line the recording shows (modulo the absolute prefix Rails prepends in a
# real app). The monorepo owns the other half of this gate: the same failure
# reached through a real Rails render, in
# docs/examples/getting-started/harness/spec/requests/getting_started_spec.rb.
# That one cannot live here — the gem repository is public and reads nothing
# from the private planning repository — which is exactly why this spec exists:
# the published artifact stays verifiable in its own repository.
RSpec.describe "the README demo's error message", :story_5_2 do
  let(:root) { Pathname.new(File.expand_path("..", __dir__)) }
  let(:fixtures) { root.join("spec/fixtures/readme") }
  let(:source) { fixtures.join("children-error.html.erb").read }
  let(:expected) { fixtures.join("children-error.txt").read.strip }

  # The exact call the recording's third beat makes, one layer down: a template
  # whose PascalCase tag has children, compiled with the guide's template path.
  def message
    Ruact::ErbPreprocessor.transform(source, identifier: "app/views/home/index.html.erb")
    raise "expected Ruact::ChildrenNotSupportedError, none was raised"
  rescue Ruact::ChildrenNotSupportedError => e
    e.message
  end

  it "is byte-for-byte what the gem produces today" do
    expect(message).to eq(expected),
                       "the loud-children message changed. The README demo at " \
                       "https://ruact.dev/readme-write-verify.gif shows the old one — " \
                       "regenerate the fixture, then RE-RECORD the demo."
  end

  it "names the component, the file:line and the fix — the three things the demo is about" do
    expect(expected).to include("<LikeButton>")
    expect(expected).to include("app/views/home/index.html.erb:3")
    expect(expected).to include("<LikeButton content={...} />")
  end

  it "is the message the README's demo is claimed to show" do
    readme = root.join("README.md").read

    expect(readme).to include("https://ruact.dev/readme-write-verify.gif")
    expect(readme).to include("Ruact::ChildrenNotSupportedError")
  end
end
