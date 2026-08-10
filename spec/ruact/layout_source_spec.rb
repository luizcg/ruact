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
  end
end
