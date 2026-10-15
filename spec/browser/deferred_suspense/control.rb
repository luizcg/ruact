# frozen_string_literal: true

require "socket"
require "json"

# Story 19-2 (AC18) — the test's side door when every Puma thread is busy: a
# listener of its own, on HARNESS_CONTROL_PORT, in the same process, that does
# not wait for a Puma thread. It opens a gate, resets them, and reads who is
# waiting and what Puma says of its threads (busy, backlog).
module Control
  def self.start(port)
    server = TCPServer.new("127.0.0.1", port)
    Thread.new do
      loop do
        client = server.accept
        serve(client)
      rescue StandardError => e
        warn("[control] #{e.class}: #{e.message}")
      ensure
        client&.close
      end
    end
  end

  def self.serve(client)
    path = client.gets.to_s.split[1].to_s
    nil until client.gets.to_s.strip.empty?
    body = JSON.generate(answer(path))
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
  end

  def self.answer(path)
    case path
    when %r{\A/open/(\w+)\z}
      Gate.open(Regexp.last_match(1))
      {}
    when "/reset"
      Gate.reset
      {}
    else { waiting: Gate.waiting, puma: puma }
    end
  end

  # Busy threads and requests queued for one, from Puma's own stats.
  def self.puma
    stats = Puma.stats_hash
    { max_threads: stats[:max_threads], busy: stats[:running].to_i - stats[:pool_capacity].to_i,
      running: stats[:running], pool_capacity: stats[:pool_capacity], backlog: stats[:backlog] }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end
end
