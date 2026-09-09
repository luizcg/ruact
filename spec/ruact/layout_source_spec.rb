# frozen_string_literal: true

require "spec_helper"
require "ruact"

# The single definition of "is this layout migrated?", shared by the runtime and
# by `ruact:install`. Every example here is a shape that fooled an earlier,
# looser check — a NAME where only a CALL counts, or a substring where only an
# attribute counts.
RSpec.describe Ruact::LayoutSource do
  describe ".wired?" do
    it "accepts a plain output tag" do
      expect(described_class.wired?("<%= ruact_js_assets %>")).to be true
    end

    it "accepts the raw-output form and tight whitespace" do
      expect(described_class.wired?("<%==ruact_js_assets%>")).to be true
    end

    it "accepts a call with an argument" do
      expect(described_class.wired?("<%= ruact_js_assets(payload) %>")).to be true
    end

    # Round-1 finding: a mention in prose read as wired.
    it "rejects a mention inside an ERB comment" do
      expect(described_class.wired?("<%# remember to add ruact_js_assets here %>")).to be false
    end

    # Round-2 finding, and the sharper version of the same mistake: a genuinely
    # COMMENTED-OUT call. ERB comments do not nest, so this emits nothing — but
    # a regex looking only for `<%=` sees a call and reports the layout ready,
    # which sends the runtime off to render an unmigrated layout.
    it "rejects a commented-out call" do
      expect(described_class.wired?("<%# <%= ruact_js_assets %> %>")).to be false
    end

    it "rejects a multi-line comment that wraps a call" do
      source = <<~ERB
        <%#
          disabled for now:
          <%= ruact_js_assets %>
        %>
      ERB
      expect(described_class.wired?(source)).to be false
    end

    it "still sees a real call that follows a comment mentioning it" do
      expect(described_class.wired?("<%# ruact_js_assets %>\n<%= ruact_js_assets %>")).to be true
    end

    # Round-3 finding: ERB's trim-mode comment (`<%-# ... -%>`) is a comment in
    # Erubi too — verified by compiling it — but the stripper only knew `<%#`,
    # so a call disabled this way read as wired.
    it "rejects a call disabled with a trim-mode comment" do
      expect(described_class.wired?("<%-# <%= ruact_js_assets %> -%>")).to be false
    end

    # Round-3 finding, the other direction: forbidding `%` before the name to
    # avoid crossing tag boundaries also rejected legitimate calls. A false
    # "unwired" is safer than a false "wired", but it is still a wrong answer —
    # the app would silently keep ruact's CSS-less shell.
    it "accepts a call whose expression contains a percent sign" do
      expect(described_class.wired?(%(<%= raw("100%") + ruact_js_assets %>))).to be true
      expect(described_class.wired?("<%= ruact_js_assets if 50 % 2 == 0 %>")).to be true
    end

    it "still refuses to match across a tag boundary" do
      expect(described_class.wired?("<%= something %> then a bare ruact_js_assets mention")).to be false
    end

    it "rejects a layout that never names it" do
      expect(described_class.wired?("<html><body><%= yield %></body></html>")).to be false
    end
  end

  describe ".root?" do
    it "accepts the emitted form" do
      expect(described_class.root?(%(<div id="root"></div>))).to be true
    end

    it "accepts single quotes, extra attributes and unquoted values" do
      expect(described_class.root?(%(<div id='root'></div>))).to be true
      expect(described_class.root?(%(<div class="a" id="root" data-x="1"></div>))).to be true
      expect(described_class.root?(%(<div id=root></div>))).to be true
    end

    # Round-2 finding: `data-id="root"` is not a mount point, and a document
    # carrying one but no real root gives React nothing to mount into.
    it "rejects a look-alike attribute" do
      expect(described_class.root?(%(<body data-id="root"></body>))).to be false
    end

    it "rejects a different id that merely starts with root" do
      expect(described_class.root?(%(<div id="rootish"></div>))).to be false
    end
  end

  # The anchor `ruact:install` injects after.
  describe "::ROOT_ELEMENT" do
    it "anchors on a whole empty root div" do
      expect(described_class::ROOT_ELEMENT).to match(%(<div id="root"></div>))
    end

    it "does not anchor on a look-alike attribute" do
      expect(described_class::ROOT_ELEMENT).not_to match(%(<div data-id="root"></div>))
    end

    # Story 17.0b — a call hidden in EITHER comment syntax is not a call.
    #
    # `without_comments` stripped only the ERB form, so `<!-- <%= ruact_js_assets %> -->`
    # read as wired: the generator skipped the migration and the doctor passed, on a
    # layout that emitted nothing. Found on the new head helper; the older one had it too.
    describe "comment handling (Story 17.0b)", :story_17_0b do
      it "does not read a call inside an HTML comment as wired", :aggregate_failures do
        expect(described_class.wired?("<!-- <%= ruact_js_assets %> -->")).to be(false)
        expect(described_class.head_wired?("<!-- <%= ruact_head_assets %> -->")).to be(false)
      end

      it "does not read a call inside an ERB comment as wired", :aggregate_failures do
        expect(described_class.wired?("<%# <%= ruact_js_assets %> %>")).to be(false)
        expect(described_class.head_wired?("<%# ruact_head_assets %>")).to be(false)
      end

      it "still reads a real call as wired", :aggregate_failures do
        expect(described_class.wired?("<%= ruact_js_assets %>")).to be(true)
        expect(described_class.head_wired?("<%= ruact_head_assets %>")).to be(true)
      end

      # An `<!--` opened INSIDE an ERB comment must not swallow through to a later
      # `-->` and blank a live call in between. One alternation, scanned left to
      # right, is what makes that true; two sequential passes got it wrong.
      it "closes whichever comment opened first" do
        source = "<%# <!-- %> <%= ruact_head_assets %> <!-- tail -->"
        expect(described_class.head_wired?(source)).to be(true)
      end
    end
  end
end
