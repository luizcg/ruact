# frozen_string_literal: true

require "spec_helper"

# A <Suspense> rendered through ActionView, as a page renders it: the text
# around the boundary is what the template wrote, line breaks included.
RSpec.describe "A <Suspense> rendered through ActionView" do
  let(:manifest) { Ruact::ClientManifest.from_hash({}) }

  it "keeps the line break after a </Suspense> written on its own line" do
    wire = PageRender.flight(%(<p>\n<Suspense fallback="L">\n<b>a</b>\n</Suspense>\nb\n</p>), manifest: manifest)
    expect(wire).to include(%("\\nb\\n"))
  end

  it "keeps a line break inside <pre> after the boundary" do
    wire = PageRender.flight(%(<pre>\n<Suspense fallback="L">x</Suspense>\nline2\n</pre>), manifest: manifest)
    expect(wire).to include(%("\\nline2\\n"))
  end
end
