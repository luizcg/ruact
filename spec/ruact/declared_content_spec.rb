# frozen_string_literal: true

require "spec_helper"

# Story 19-2 (AC10) — what a deferred block declares with `content_for`. The
# view's record is Rails' own (`ActionView::OutputFlow`): `content_for?` and
# `yield :name` read it with `get`, `content_for` writes it with `append`. Not
# an `ActionView::Base`: building one here would run Action View's load hooks
# before the request specs boot their app.
RSpec.describe Ruact::DeclaredContent do
  let(:view) { Struct.new(:view_flow).new(ActionView::OutputFlow.new) }

  # Review 19-2a R2 — Rails records every name it is asked for, empty.
  it "takes a name only read (content_for?, yield) for no declaration" do
    before = described_class.take(view)
    view.view_flow.get(:nobody_set_it)
    expect { described_class.check!(view, before) }.not_to raise_error
  end

  it "takes a name given content for a declaration" do
    before = described_class.take(view)
    view.view_flow.append(:title, "late")
    expect { described_class.check!(view, before) }.to raise_error(Ruact::Error, /content_for :title/)
  end

  it "takes content added to a name already declared for a declaration" do
    view.view_flow.append(:title, "early")
    before = described_class.take(view)
    view.view_flow.append(:title, " and late")
    expect { described_class.check!(view, before) }.to raise_error(Ruact::Error, /content_for :title/)
  end
end
