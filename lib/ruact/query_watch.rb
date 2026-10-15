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
  # Not cancelled: a query `load_async` runs. The async executor's thread holds
  # its connection, not the block's, and nothing ties that query to the block
  # that waits for it; it runs to its end. The statement timeout is the limit
  # for those.
  #
  # Internal API: not part of the public compatibility contract.
  class QueryWatch
    # Who holds a connection the way Active Record records it: the thread, or
    # the fiber under `isolation_level = :fiber`.
    def self.current_owner
      ::ActiveSupport::IsolatedExecutionState.context
    end

    # Watches +owner+'s connections for +limit+ seconds; nil when there is
    # nothing to watch (no Active Record).
    def self.start(owner, limit)
      return nil unless defined?(::ActiveRecord::Base) && defined?(::PG::Connection)

      new(owner, limit)
    end

    def initialize(owner, limit)
      @lock = Mutex.new
      @done = false
      @cancelled = false
      @watcher = Thread.new do
        sleep(limit)
        @lock.synchronize { cancel_queries_of(owner) unless @done }
      end
    end

    # The block ran past the limit and was given back: cancel what its owner
    # still has in flight now, whether or not the watcher got there first.
    def cancel_now(owner)
      @lock.synchronize { cancel_queries_of(owner) }
    end

    # Whether a query was cancelled: the error the block then raises
    # (`ActiveRecord::QueryCanceled`) is the timeout's, not the content's. The
    # watcher can get there before `Timeout` does.
    def cancelled?
      @lock.synchronize { @cancelled }
    end

    # The block ended (or was ended): nothing to cancel any more.
    def stop
      @lock.synchronize { @done = true }
      @watcher.kill
    end

    private

    def cancel_queries_of(owner)
      ::ActiveRecord::Base.connection_handler.connection_pool_list(:all).each do |pool|
        # Under the pool's lock: a connection nobody holds is not handed to
        # another request between the check and the cancel.
        pool.synchronize { pool.connections.each { |connection| cancel_query_on(connection, owner) } }
      end
    rescue StandardError
      nil
    end

    # The owner's own connection, or one already back in the pool: unwinding a
    # `with_connection` gives the connection back with its query still running.
    # A query in flight on a connection nobody holds is one nobody waits for.
    def cancel_query_on(connection, owner)
      return unless connection.owner.nil? || connection.owner.equal?(owner)

      raw = connection.instance_variable_get(:@raw_connection)
      return unless raw.is_a?(::PG::Connection) && raw.transaction_status == ::PG::PQTRANS_ACTIVE

      raw.cancel
      @cancelled = true
    end
  end
end
