# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "ruact/load_async_note"

# Story 19-1 (ADR D1) — a `load_async` that cannot run in the background says
# so in development, once per process.
RSpec.describe Ruact::LoadAsyncNote do
  let(:log) { StringIO.new }

  before do
    described_class.reset!
    allow(Rails).to receive(:logger).and_return(Logger.new(log))
  end

  after { described_class.reset! }

  it "names the setting and the value to put, the first time there is no executor" do
    described_class.note(nil)
    expect(log.string).to include("config.active_record.async_query_executor = :global_thread_pool")
  end

  it "says it once" do
    2.times { described_class.note(nil) }
    expect(log.string.scan("load_async ran its query").length).to eq(1)
  end

  it "says nothing when there is an executor" do
    described_class.note(:global_thread_pool)
    expect(log.string).to be_empty
  end

  describe "in a relation" do
    let(:relation) do
      Class.new do
        def load_async = :loaded
        prepend Ruact::LoadAsyncNote::Relation
      end.new
    end

    around do |example|
      require "active_record"
      executor = ActiveRecord.async_query_executor
      example.run
    ensure
      ActiveRecord.async_query_executor = executor
    end

    it "notes, then loads as Rails does", :aggregate_failures do
      ActiveRecord.async_query_executor = nil
      expect(relation.load_async).to eq(:loaded)
      expect(log.string).to include("load_async ran its query")
    end
  end
end
