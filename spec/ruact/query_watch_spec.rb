# frozen_string_literal: true

require "spec_helper"

# Story 19-2 (AC14) — at suspense_timeout, a query still in flight is cancelled
# on the server. Proved against PostgreSQL by the browser harness (`./run pg`);
# here, which connections it touches.
RSpec.describe Ruact::QueryWatch do
  let(:active) { 1 }
  let(:fake_pg) do
    Class.new do
      attr_reader :status, :cancelled

      def initialize(status)
        @status = status
        @cancelled = false
      end

      def transaction_status = @status

      def cancel
        @cancelled = true
        nil
      end
    end
  end
  let(:block_thread) { Thread.current }
  let(:other_thread) { Thread.new { sleep }.tap { |t| t.join(0.01) } }

  # What QueryWatch reads of a connection, a pool and the handler.
  let(:fake_connection) do
    Struct.new(:owner, :raw) do
      def initialize(owner, raw)
        super
        @raw_connection = raw
      end
    end
  end
  let(:fake_pool) do
    Struct.new(:connections) do
      def synchronize = yield
    end
  end
  let(:fake_handler) do
    Struct.new(:pools) do
      def connection_pool_list(_role) = pools
    end
  end

  def connection(owner, raw) = fake_connection.new(owner, raw)

  def handle(connections)
    allow(ActiveRecord::Base).to receive(:connection_handler)
      .and_return(fake_handler.new([fake_pool.new(connections)]))
  end

  before do
    stub_const("PG::Connection", fake_pg)
    stub_const("PG::PQTRANS_ACTIVE", active)
    stub_const("ActiveRecord::Base", Class.new { def self.connection_handler = nil })
  end

  after { other_thread.kill }

  def watch_over(connections)
    handle(connections)
    described_class.start(block_thread, 60)
  end

  it "cancels a query in flight on the block's connection, and on one already back in the pool", :aggregate_failures do
    mine = fake_pg.new(active)
    returned = fake_pg.new(active)
    watch = watch_over([connection(block_thread, mine), connection(nil, returned)])
    watch.cancel_now(block_thread)
    watch.stop
    expect(mine.cancelled).to be(true)
    expect(returned.cancelled).to be(true)
  end

  it "leaves another thread's query, and a connection with nothing in flight", :aggregate_failures do
    theirs = fake_pg.new(active)
    idle = fake_pg.new(0)
    watch = watch_over([connection(other_thread, theirs), connection(block_thread, idle)])
    watch.cancel_now(block_thread)
    watch.stop
    expect(theirs.cancelled).to be(false)
    expect(idle.cancelled).to be(false)
  end

  it "cancels on its own at the limit when the block is stuck, and not after it stopped", :aggregate_failures do
    stuck = fake_pg.new(active)
    handle([connection(block_thread, stuck)])

    watch = described_class.start(block_thread, 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.01 until stuck.cancelled || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    watch.stop
    expect(stuck.cancelled).to be(true)

    finished = fake_pg.new(active)
    handle([connection(block_thread, finished)])
    described_class.start(block_thread, 0.05).stop
    sleep 0.15
    expect(finished.cancelled).to be(false)
  end

  # Review 19-2a R1 — under `isolation_level = :fiber` Active Record records
  # the fiber as a connection's owner, not the thread.
  it "cancels a query of the fiber that holds the connection", :aggregate_failures do
    fiber = Fiber.new { nil }
    mine = fake_pg.new(active)
    watch = watch_over([connection(fiber, mine)])
    watch.cancel_now(block_thread)
    expect(mine.cancelled).to be(false)
    watch.cancel_now(fiber)
    watch.stop
    expect(mine.cancelled).to be(true)
  end

  it "takes the owner as Active Record records it" do
    expect(described_class.current_owner).to equal(ActiveSupport::IsolatedExecutionState.context)
  end

  it "says whether it cancelled a query", :aggregate_failures do
    watch = watch_over([connection(block_thread, fake_pg.new(0))])
    watch.cancel_now(block_thread)
    expect(watch.cancelled?).to be(false)
    handle([connection(block_thread, fake_pg.new(active))])
    watch.cancel_now(block_thread)
    watch.stop
    expect(watch.cancelled?).to be(true)
  end

  it "watches nothing without PostgreSQL's driver" do
    hide_const("PG::Connection")
    expect(described_class.start(block_thread, 1)).to be_nil
  end
end
