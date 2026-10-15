# frozen_string_literal: true

module Ruact
  # Story 19-2 (AC14) — when a `<Suspense>` runs past `suspense_timeout` with a
  # query in flight, that query is cancelled on the database server.
  #
  # `Timeout` gives the block back at the limit, but a query the driver is
  # waiting on keeps running on the server, and the connection stays busy with
  # it: the next query on it — this response's, or the next request's once the
  # connection is back in the pool — waits for it to end (measured with
  # PostgreSQL: seconds). Inside a transaction even the unwinding waits, at its
  # ROLLBACK. So at the limit the queries in flight on the connections the
  # block's thread holds — or that it already gave back — are cancelled, from
  # another thread if the block is stuck; the connection is free again within
  # milliseconds.
  #
  # PostgreSQL only: `PG::Connection#cancel` is libpq's PQcancel, made to be
  # called from another thread. Other adapters are left as they are; the
  # database's own statement timeout is the limit there.
  #
  # Internal API: not part of the public compatibility contract.
  class QueryWatch
    # Watches +thread+'s connections for +limit+ seconds; nil when there is
    # nothing to watch (no Active Record).
    def self.start(thread, limit)
      return nil unless defined?(::ActiveRecord::Base) && defined?(::PG::Connection)

      new(thread, limit)
    end

    def initialize(thread, limit)
      @lock = Mutex.new
      @done = false
      @watcher = Thread.new do
        sleep(limit)
        @lock.synchronize { cancel_queries_of(thread) unless @done }
      end
    end

    # The block ran past the limit and was given back: cancel what its thread
    # still has in flight now, whether or not the watcher got there first.
    def cancel_now(thread)
      @lock.synchronize { cancel_queries_of(thread) }
    end

    # The block ended (or was ended): nothing to cancel any more.
    def stop
      @lock.synchronize { @done = true }
      @watcher.kill
    end

    private

    def cancel_queries_of(thread)
      ::ActiveRecord::Base.connection_handler.connection_pool_list(:all).each do |pool|
        pool.connections.each do |connection|
          # The block's thread's own, or one already back in the pool: unwinding
          # a `with_connection` gives the connection back with its query still
          # running. A query in flight on a connection nobody holds is one
          # nobody waits for.
          next unless connection.owner.nil? || connection.owner.equal?(thread)

          raw = connection.instance_variable_get(:@raw_connection)
          next unless raw.is_a?(::PG::Connection)
          next unless raw.transaction_status == ::PG::PQTRANS_ACTIVE

          raw.cancel
        end
      end
    rescue StandardError
      nil
    end
  end
end
