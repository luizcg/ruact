# frozen_string_literal: true

# Story 19-1, AC5.4 — what `suspense_timeout` does to a query running in
# PostgreSQL. ruact bounds a block with `Timeout.timeout(limit)` (no exception
# class); this runs that call around a query that takes longer, on a throwaway
# server (`./run postgres` starts it), and writes results/postgres.md.
#
#   bundle exec ruby measure/postgres.rb SOCKET_DIR PORT

require "bundler/setup"
require "active_record"
require "timeout"

socket_dir, port = ARGV
ActiveRecord::Base.establish_connection(adapter: "postgresql", host: socket_dir, port: Integer(port),
                                        database: "postgres", pool: 3)

LIMIT = 1
QUERY = "SELECT pg_sleep(4)"
rows = []

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# What the server is still running, asked on a connection of its own.
def still_running(label)
  conn = PG.connect(host: ARGV[0], port: Integer(ARGV[1]), dbname: "postgres")
  count = conn.exec("SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%pg_sleep(4)%' " \
                    "AND pid <> pg_backend_pid()").getvalue(0, 0).to_i
  conn.close
  "#{label}: #{count}"
end

# 1. The timeout ruact puts around a block, around the query.
started = clock
outcome = begin
  Timeout.timeout(LIMIT) { ActiveRecord::Base.lease_connection.select_value(QUERY) }
  "returned"
rescue Exception => e # rubocop:disable Lint/RescueException -- what reaches here is the measurement
  "#{e.class}: #{e.message}"
end
elapsed = clock - started
running = still_running("queries still running on the server right after")
after_started = clock
after = begin
  "#{ActiveRecord::Base.lease_connection.select_value('SELECT 1').inspect} " \
  "in #{format('%.2f', clock - after_started)}s"
rescue StandardError => e
  "#{e.class}: #{e.message}"
end
rows << ["`Timeout.timeout(#{LIMIT})` around `#{QUERY}`", format("%.2fs", elapsed), outcome, running,
         "the same connection's next query: #{after}"]
ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

# 2. The database's own limit.
started = clock
outcome = begin
  ActiveRecord::Base.lease_connection.transaction do
    ActiveRecord::Base.lease_connection.execute("SET LOCAL statement_timeout = '#{LIMIT}s'")
    ActiveRecord::Base.lease_connection.select_value(QUERY)
  end
  "returned"
rescue StandardError => e
  e.class.to_s
end
elapsed = clock - started
rows << ["`SET LOCAL statement_timeout = '#{LIMIT}s'` around `#{QUERY}`", format("%.2fs", elapsed), outcome,
         still_running("queries still running on the server right after"), ""]

server = ActiveRecord::Base.lease_connection.select_value("SHOW server_version")
File.write(File.join(__dir__, "..", "results", "postgres.md"), <<~MD)
  # Story 19-1 — `suspense_timeout` and a query running in PostgreSQL

  Written by `./run postgres`: PostgreSQL #{server}, pg #{PG::VERSION}, Active Record #{ActiveRecord::VERSION::STRING},
  Ruby #{RUBY_VERSION}. A throwaway server, one query at a time.

  | what | took | what the caller got | on the server | after |
  | --- | --- | --- | --- | --- |
  #{rows.map { |row| "| #{row.join(' | ')} |" }.join("\n")}
MD
puts File.read(File.join(__dir__, "..", "results", "postgres.md"))
