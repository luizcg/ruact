# frozen_string_literal: true

# Story 19-0 — the measurements that need no browser. Each one boots the app
# with the configuration it is about, drives it over HTTP with the gate, and
# appends what it saw to results/http.md.
#
#   bundle exec ruby measure/measure.rb            # all of them
#   bundle exec ruby measure/measure.rb buffering  # one section
#
# `npx vite build` must have run (production reads the built manifest).

require "json"
require "net/http"
require "open3"
require "socket"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT  = File.join(ROOT, "results", "http.md")
TMP  = Dir.mktmpdir("spike-19-0")
REPORT = [] # rubocop:disable Style/MutableConstant

def say(line = "")
  puts line
  REPORT << line
end

def free_port
  server = TCPServer.new("127.0.0.1", 0)
  server.addr[1]
ensure
  server&.close
end

def http(base, path, method: :get, headers: {})
  uri = URI("#{base}#{path}")
  Net::HTTP.start(uri.host, uri.port, read_timeout: 90) do |http|
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri, headers)
    http.request(request)
  end
end

def state(base)
  JSON.parse(http(base, "/__state").body)
end

def wait_for(what, limit: 15)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
  loop do
    value = yield
    return value if value
    raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.02
  end
end

# Like wait_for, for the outcome that may never come: false after `limit`.
def within?(limit)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
  loop do
    return true if yield
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.02
  end
end

def open_gate(base, name)
  http(base, "/__gate/#{name}/open", method: :post)
end

def reset(base)
  http(base, "/__gate/reset", method: :post)
end

def with_server(env = {})
  port = free_port
  log = File.join(TMP, "puma-#{port}.log")
  full = { "PORT" => port.to_s, "RAILS_ENV" => "development", "SPIKE_MODE" => "live" }.merge(env)
  pid = Process.spawn(full, "bundle", "exec", "puma", "-t", "3:3", "-p", port.to_s, "config.ru",
                      chdir: ROOT, out: log, err: log, pgroup: true)
  base = "http://127.0.0.1:#{port}"
  wait_for("server on #{port}", limit: 60) do
    http(base, "/up").code == "200"
  rescue SystemCallError, EOFError
    raise "server exited:\n#{File.read(log)}" if Process.wait(pid, Process::WNOHANG)

    false
  end
  yield base
ensure
  if pid
    begin
      Process.kill("TERM", -Process.getpgid(pid))
      Process.wait(pid)
    rescue SystemCallError
      nil
    end
  end
end

# A client that keeps what it has received so far in a file.
class Curl
  attr_reader :pid, :body, :head

  def initialize(base, path, flight: false, compressed: false)
    @body = File.join(TMP, "body-#{rand(1 << 32)}")
    @head = "#{@body}.headers"
    args = ["curl", "-sN", "-D", @head, "-o", @body]
    args += ["-H", "Accept: text/x-component"] if flight
    args << "--compressed" if compressed
    @pid = Process.spawn(*args, "#{base}#{path}")
  end

  def received
    File.exist?(@body) ? File.binread(@body).force_encoding("UTF-8") : ""
  end

  def headers
    File.exist?(@head) ? File.read(@head) : ""
  end

  def header(name)
    headers[/^#{Regexp.escape(name)}:\s*(.*?)\r?$/i, 1]
  end

  def disconnect
    Process.kill("KILL", @pid)
    Process.wait(@pid)
  end

  def finish
    Process.wait(@pid)
    received
  end
end

SECTIONS = {} # rubocop:disable Style/MutableConstant

def section(name, &block)
  SECTIONS[name] = block
end

# ---------------------------------------------------------------------------

section "baseline" do
  say "## Baseline: ruact 0.0.19 with ActionController::Live"
  say
  with_server("SPIKE_MODE" => "baseline") do |base|
    %w[flight document].each do |kind|
      reset(base)
      client = Curl.new(base, "/slow", flight: kind == "flight")
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      arrived = within?(1.0) { !client.received.empty? || !client.headers.empty? }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      open_gate(base, "a")
      client.finish
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      say "- #{kind}: with the gate closed, headers or body received within 1 s = **#{arrived}**; " \
          "after the gate opened the response took #{format('%.2f', took)} s to complete"
    end
  end
  say
end

section "buffering" do
  say "## Buffering: does the shell reach the client while the gate is closed?"
  say
  say "| mechanism | environment | extra middleware | response | shell before the gate opens | headers that matter |"
  say "| --- | --- | --- | --- | --- | --- |"
  %w[live body].each do |mode|
    %w[development production].each do |env|
      [{}, { "SPIKE_DEFLATER" => "1" }, { "SPIKE_BARE_HEADERS" => "1" }].each do |extra|
        label = extra.keys.first&.sub("SPIKE_", "")&.downcase || "none (defaults)"
        with_server({ "SPIKE_MODE" => mode, "RAILS_ENV" => env }.merge(extra)) do |base|
          %w[flight document].each do |kind|
            reset(base)
            client = Curl.new(base, "/slow", flight: kind == "flight", compressed: extra.key?("SPIKE_DEFLATER"))
            wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
            arrived = within?(2.0) { client.received.include?("Loading A") }
            open_gate(base, "a")
            body = client.finish
            raise "content never arrived (#{mode} #{env} #{label} #{kind})" unless body.include?("open:a")

            kept = %w[cache-control etag content-encoding transfer-encoding content-length x-accel-buffering]
                   .filter_map { |name| (value = client.header(name)) && "`#{name}: #{value}`" }.join(", ")
            say "| #{mode} | #{env} | #{label} | #{kind} | **#{arrived ? 'yes' : 'NO'}** | #{kept} |"
          end
        end
      end
    end
  end
  say
end

section "middleware" do
  say "## The middleware stack the measurements ran on"
  say
  say "Compared with `bin/rails middleware` in an app generated by `rails _8.1.4_ new` " \
      "(`measure/rails_new_middleware.txt`)."
  say
  reference = File.readlines(File.join(__dir__, "rails_new_middleware.txt")).grep_v(/^#/).to_h do |line|
    env, list = line.split(":", 2)
    [env, list.split]
  end
  %w[development production].each do |env|
    out, = Open3.capture2({ "RAILS_ENV" => env, "SPIKE_MODE" => "body" }, "bundle", "exec", "ruby", "-e",
                          'require "./app"; puts(Rails.application.middleware.map { |m| m.klass.is_a?(Class) ? m.klass.to_s : m.klass.class.to_s })',
                          chdir: ROOT)
    stack = out.split("\n")
    own = %w[ThreadMarker Ruact::NavigationBoundary::Middleware]
    same = (stack - own) == reference.fetch(env)
    say "- **#{env}**: same classes in the same order as the generated app = **#{same}**, plus " \
        "#{own.map { |m| "`#{m}`" }.join(' and ')} at the end."
    say "  - missing here: #{(reference.fetch(env) - stack).join(', ')}" unless same
    say "  - extra here: #{(stack - own - reference.fetch(env)).join(', ')}" unless same
    say "  - #{stack.map { |m| "`#{m}`" }.join(' → ')}"
  end
  say
end

section "disconnect" do
  say "## A client that goes away while a block is waiting"
  say
  say "\"Still waiting\" and \"started\" are read up to 1 s and 2 s after the event: a bound, where every other " \
      "line here is an order."
  say
  [["live", nil], ["body", nil], %w[live 1], %w[body 1]].each do |mode, peek|
    env = { "SPIKE_MODE" => mode }
    env["SPIKE_PEEK"] = "1" if peek
    mode = "#{mode}, asking the socket before each block" if peek
    with_server(env) do |base|
      # One slow query: the connection it holds.
      reset(base)
      client = Curl.new(base, "/db")
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      wait_for("shell") { client.received.include?("Loading A") }
      busy_before = state(base)["pool"]["busy"]
      client.disconnect
      still_waiting = !within?(1.0) { state(base)["waiting"].empty? }
      busy_gone = state(base)["pool"]["busy"]
      open_gate(base, "a")
      wait_for("the block to finish") { state(base)["events"].include?("block_end:0") }
      wait_for("the pool") { state(base)["pool"]["busy"].zero? }
      settled = wait_for("the response to end") { state(base)["events"].grep(/disconnected|complete|client_gone/).any? }
      say "- **#{mode}**, one slow query (`/db`): connections busy while waiting = #{busy_before}; " \
          "after the client left, the block was still waiting = #{still_waiting} (busy = #{busy_gone}); " \
          "after the gate opened, busy = #{state(base)['pool']['busy']}; events = `#{state(base)['events'].join(' → ')}`"
      _ = settled

      # Two blocks: is the second one started for a client that is gone?
      reset(base)
      client = Curl.new(base, "/two")
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      wait_for("shell") { client.received.include?("Loading A") }
      client.disconnect
      open_gate(base, "a")
      wait_for("block a") { state(base)["events"].include?("block_end:0") }
      started_b = within?(2.0) { state(base)["waiting"] == { "b" => 1 } }
      open_gate(base, "b")
      begin
        wait_for("the end") { state(base)["events"].grep(/disconnected|complete|client_gone/).any? }
      rescue RuntimeError
        raise "no end after both gates opened (#{mode}): #{state(base).slice('events', 'waiting')}\n" \
              "#{File.read(Dir[File.join(TMP, 'puma-*.log')].max_by { |f| File.mtime(f) }).lines.last(25).join}\n" \
              "#{File.read(File.join(ROOT, 'log', 'development.log')).lines.last(40).join}"
      end
      say "- **#{mode}**, two blocks (`/two`): the second block started for a client that had left = **#{started_b}**; " \
          "events = `#{state(base)['events'].join(' → ')}`"
    end
  end
  say
end

section "timeout" do
  say "## A block that runs past `suspense_timeout` (set to 1 s)"
  say
  %w[live body].each do |mode|
    with_server("SPIKE_MODE" => mode, "SPIKE_TIMEOUT" => "1") do |base|
      reset(base)
      client = Curl.new(base, "/timeout", flight: true)
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      busy = state(base)["pool"]["busy"]
      body = client.finish
      after = state(base)
      error_row = body.lines.find { |line| line.include?(":E{") }
      query = http(base, "/same", headers: { "Accept" => "text/x-component" })
      say "- **#{mode}**, the client stays: busy while waiting = #{busy}; error row = `#{error_row&.strip}`; " \
          "the next block arrived = #{body.include?('b is quick')}; afterwards waiting = #{after['waiting']}, " \
          "pool = busy #{after['pool']['busy']} / idle #{after['pool']['idle']} / dead #{after['pool']['dead']}; " \
          "a page that queries the same pool afterwards = #{query.code}, rows read = #{query.body.scan('"li"').length}"

      # The same limit on a query that runs inside the database instead of waiting in Ruby.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      body = http(base, "/timeout_real", headers: { "Accept" => "text/x-component" }).body
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      outcome = body.include?("ruact:suspense-timeout") ? "the timeout row" : "its content"
      say "- **#{mode}**, a query that runs inside SQLite (`/timeout_real`): the response took #{format('%.1f', took)} s " \
          "against the 1 s limit, and the boundary got **#{outcome}**"

      # The client leaves and the gate is never opened: only the timeout can end the block.
      reset(base)
      client = Curl.new(base, "/db")
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      wait_for("shell") { client.received.include?("Loading A") }
      busy = state(base)["pool"]["busy"]
      client.disconnect
      # The order this line is about: the client was gone while the block still waited.
      raise "the timeout fired before the client had left" unless state(base)["waiting"] == { "a" => 1 }

      wait_for("the timeout") { state(base)["waiting"].empty? }
      wait_for("the pool") { state(base)["pool"]["busy"].zero? }
      say "- **#{mode}**, the client leaves and the gate never opens: busy while waiting = #{busy}, " \
          "and the block was still waiting once the client had left; " \
          "after the timeout, waiting = #{state(base)['waiting']} and busy = #{state(base)['pool']['busy']}; " \
          "events = `#{state(base)['events'].join(' → ')}`"
    end
  end
  say
end

section "load_async" do
  say "## `load_async` in the controller, consumed inside two boundaries (`/db_async`)"
  say
  [%w[live 1], ["live", nil], %w[baseline 1]].each do |mode, async|
    env = { "SPIKE_MODE" => mode }
    env["SPIKE_ASYNC"] = "1" if async
    with_server(env) do |base|
      reset(base)
      client = Curl.new(base, "/db_async", flight: true)
      label = "#{mode}, async_query_executor = #{state(base)['async_executor']}"
      first = wait_for("a gate") { (waiting = state(base)["waiting"]) && !waiting.empty? && waiting }
      both = within?(1.5) { state(base)["waiting"] == { "a" => 1, "b" => 1 } }
      waiting = state(base)["waiting"]
      shell = within?(1.0) { client.received.include?("Loading A") }
      busy = state(base)["pool"]["busy"]
      open_gate(base, "b")
      b_first = within?(1.5) { client.received.include?('"id":"b"') }
      open_gate(base, "a")
      body = client.finish
      raise "incomplete: #{body}" unless body.include?('"id":"a"') && body.include?('"id":"b"')

      say "- **#{label}**: first seen waiting = #{first}; both queries running at once = **#{both}** " \
          "(waiting = #{waiting}, connections busy = #{busy}); shell at the client before any gate opened = **#{shell}**; " \
          "with gate b opened first, b's row arrived before a's gate opened = **#{b_first}**"
    end
  end
  say
end

section "live_cost" do
  say "## What `ActionController::Live` costs a page with no Suspense (`/plain`, production)"
  say
  say "Throughput is three 4-second `wrk` runs after a warm-up, on a machine doing other things: " \
      "read the spread between runs before reading a difference between rows."
  say
  unless system("which wrk > /dev/null 2>&1")
    say "- not measured: `wrk` is not installed"
    say
    next
  end
  throughput = lambda do |url, *headers|
    Open3.capture2("wrk", "-t1", "-c3", "-d2s", *headers.flat_map { |h| ["-H", h] }, url) # warm-up
    Array.new(3) do
      out, = Open3.capture2("wrk", "-t1", "-c3", "-d4s", *headers.flat_map { |h| ["-H", h] }, url)
      out[%r{Requests/sec:\s+([\d.]+)}, 1].to_f.round
    end
  end
  configurations = {
    "Live on every action" => { "SPIKE_MODE" => "live" },
    "Live chosen per action, `plain` left out" => { "SPIKE_MODE" => "live", "SPIKE_SELECTIVE" => "1" },
    "no Live (lazy body)" => { "SPIKE_MODE" => "body" }
  }
  configurations.each do |label, env|
    with_server(env.merge("RAILS_ENV" => "production")) do |base|
      first = http(base, "/plain")
      flight = http(base, "/plain", headers: { "Accept" => "text/x-component" })
      revalidated = flight["etag"] &&
                    http(base, "/plain", headers: { "Accept" => "text/x-component", "If-None-Match" => flight["etag"] })
      thread = flight.body.force_encoding("UTF-8")[/"id":"thread","children":"(.*?)"/, 1]
      document = throughput.call("#{base}/plain")
      navigation = throughput.call("#{base}/plain", "Accept: text/x-component")

      # A page that does stream still works in this configuration.
      reset(base)
      client = Curl.new(base, "/slow", flight: true)
      wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
      streams = within?(2.0) { client.received.include?("Loading A") }
      open_gate(base, "a")
      client.finish

      headers = %w[cache-control etag content-length transfer-encoding].filter_map do |n|
        first[n] && "`#{n}: #{first[n]}`"
      end
      say "- **#{label}**: the action runs on the #{thread}; document #{document.join(' / ')} req/s, " \
          "Flight #{navigation.join(' / ')} req/s (wrk, 3 runs of 4 s, 3 connections); document headers: #{headers.join(', ')}; " \
          "Flight response: #{flight['etag'] ? "ETag sent, `If-None-Match` → #{revalidated.code}" : 'no ETag'}; " \
          "`/slow` still sends its shell before the gate opens = #{streams}"
    end
  end
  say
end

section "after_action" do
  say "## An `after_action` that sets a header and a cookie"
  say
  say "The filter waits at a gate before it writes, so the order is a fact: were the response's headers " \
      "already at the client while the filter was still running?"
  say
  say "| configuration | page | response | headers sent before the filter finished | the filter's header | the filter's cookie |"
  say "| --- | --- | --- | --- | --- | --- |"
  configurations = {
    "0.0.19 with Live (today)" => { "SPIKE_MODE" => "baseline" },
    "prototype, Live on every action" => { "SPIKE_MODE" => "live" },
    "prototype, Live per action (`plain` left out)" => { "SPIKE_MODE" => "live", "SPIKE_SELECTIVE" => "1" },
    "prototype, no Live (lazy body)" => { "SPIKE_MODE" => "body" }
  }
  configurations.each do |label, env|
    with_server(env) do |base|
      [["/plain", "no Suspense"], ["/slow", "one Suspense"]].each do |path, page|
        %w[document flight].each do |kind|
          reset(base)
          open_gate(base, "a")
          client = Curl.new(base, "#{path}?hold=1", flight: kind == "flight")
          wait_for("the filter") { state(base)["waiting"] == { "after" => 1 } }
          early = within?(1.0) { client.headers.include?("\r\n\r\n") }
          open_gate(base, "after")
          client.finish
          header = client.header("x-after-action") ? "arrives" : "**lost**"
          cookie = client.headers.match?(/^set-cookie: after_action=/i) ? "arrives" : "**lost**"
          say "| #{label} | #{page} | #{kind} | #{early ? '**yes**' : 'no'} | #{header} | #{cookie} |"
        end
      end
    end
  end
  say
  say "With no gate, the same writes race the headers being sent. Each cell is how many of 600 responses " \
      "carried them: 3 clients at once, 200 requests each, against Puma's 3 threads."
  say
  say "| configuration | what writes | response | header arrived | cookie arrived |"
  say "| --- | --- | --- | --- | --- |"
  racing = {
    "prototype, Live on every action" => { "SPIKE_MODE" => "live" },
    "prototype, no Live (lazy body)" => { "SPIKE_MODE" => "body" }
  }
  burst = lambda do |base, path, accept|
    Array.new(3) { Thread.new { Array.new(200) { http(base, path, headers: { "Accept" => accept }) } } }.flat_map(&:value)
  end
  cookie = ->(responses, name) { responses.count { |r| r.get_fields("set-cookie").to_a.any? { |c| c.start_with?("#{name}=") } } }
  racing.each do |label, env|
    with_server(env) do |base|
      %w[text/html text/x-component].each do |accept|
        kind = accept == "text/html" ? "document" : "flight"
        responses = burst.call(base, "/plain", accept)
        say "| #{label} | an `after_action`, page with no Suspense | #{kind} | " \
            "#{responses.count { |r| r['x-after-action'] }} / 600 | #{cookie.call(responses, 'after_action')} / 600 |"

        open_gate(base, "a")
        responses = burst.call(base, "/late_cookie", accept)
        say "| #{label} | a `<Suspense>` block that does not wait | #{kind} | — | #{cookie.call(responses, 'late')} / 600 |"
        reset(base)
      end
    end
  end
  say
end

section "leased_connection" do
  say "## A connection leased with `Model.connection` (`/leased`, a page with no Suspense)"
  say
  say "Rails returns such a connection when the request ends. Read after the responses were complete."
  say
  configurations = {
    "0.0.19 with Live (today)" => { "SPIKE_MODE" => "baseline" },
    "prototype, Live on every action" => { "SPIKE_MODE" => "live" },
    "prototype, no Live (lazy body)" => { "SPIKE_MODE" => "body" }
  }
  configurations.each do |label, env|
    with_server(env) do |base|
      reset(base)
      http(base, "/leased", headers: { "Accept" => "text/x-component" })
      one = state(base)["pool"]["busy"]

      # Two at once (Puma's third thread answers the probe): each waits at the
      # gate, so that both are in their action together.
      clients = Array.new(2) { Curl.new(base, "/leased?hold=1", flight: true) }
      wait_for("two actions") { state(base)["waiting"] == { "a" => 2 } }
      open_gate(base, "a")
      clients.each(&:finish)
      two = state(base)["pool"]["busy"]
      say "- **#{label}**: connections still busy after one request = **#{one}**; after two more at once = **#{two}** " \
          "(pool of #{state(base)['pool']['size']})"
    end
  end
  say
end

section "unchanged" do
  say "## A page with no Suspense (`/same`): what the prototype sends against what 0.0.19 sends"
  say
  responses = {}
  { "0.0.19" => "baseline", "prototype, Live" => "live", "prototype, lazy body" => "body" }.each do |label, mode|
    with_server("SPIKE_MODE" => mode, "RAILS_ENV" => "production") do |base|
      flight = http(base, "/same", headers: { "Accept" => "text/x-component" }).body
      document = http(base, "/same").body
      responses[label] = { flight: flight, inline: document[/d\.push\((".*?")\);/m, 1] }
    end
  end
  reference = responses.delete("0.0.19")
  raise "no payload found in the 0.0.19 document" if reference[:inline].to_s.empty?

  responses.each do |label, response|
    say "- **#{label}**: Flight body identical to 0.0.19's = **#{response[:flight] == reference[:flight]}** " \
        "(#{response[:flight].bytesize} bytes); payload inlined in the document identical = " \
        "**#{response[:inline] == reference[:inline]}**"
  end
  say
end

section "middleware_state" do
  say "## What a middleware scoped around the request (`/mw`)"
  say
  say "The middleware wraps the app in `I18n.with_locale(:pt)` and in " \
      "`ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true)`. The block waits at a gate, " \
      "which opens only after the client has the response's headers: the middleware has returned by then."
  say
  read = ->(body, id) { body[/"id":"#{id}","children":"(.*?)"\}/, 1] }
  probe = lambda do |base, released|
    reset(base)
    client = Curl.new(base, "/mw", flight: true)
    wait_for("gate a") { state(base)["waiting"] == { "a" => 1 } }
    # 0.0.19 sends nothing before the block has run: there the block is
    # evaluated while the middleware is still waiting for the action.
    wait_for("headers") { client.headers.include?("\r\n\r\n") } if released
    open_gate(base, "a")
    body = client.finish
    "shell: locale `#{read.call(body, 'shell-locale')}`, writes #{read.call(body, 'shell-writes')}, " \
      "the middleware's thread variable `#{read.call(body, 'shell-variable')}`; " \
      "block: locale `#{read.call(body, 'block-locale')}`, writes #{read.call(body, 'block-writes')}"
  end
  locale_of = ->(base) { read.call(http(base, "/locale", headers: { "Accept" => "text/x-component" }).body, "shell-locale") }

  { "0.0.19 with Live (today)" => "baseline", "prototype, Live" => "live", "prototype, lazy body" => "body" }.each do |label, mode|
    with_server("SPIKE_MODE" => mode) do |base|
      say "- **#{label}**, `/mw` as the server's first request — #{probe.call(base, mode != 'baseline')}. " \
          "A page with no such middleware, right after: locale `#{locale_of.call(base)}`"
    end
    with_server("SPIKE_MODE" => mode) do |base|
      before = locale_of.call(base)
      say "- **#{label}**, `/mw` after another page (locale `#{before}`) has run — #{probe.call(base, mode != 'baseline')}"
    end
  end
  say
end

section "virtual_path" do
  say "## The template path inside a deferred block"
  say
  [nil, "1"].each do |off|
    env = { "SPIKE_MODE" => "live" }
    env["SPIKE_NO_VPATH"] = "1" if off
    with_server(env) do |base|
      reset(base)
      open_gate(base, "a")
      body = http(base, "/context", headers: { "Accept" => "text/x-component" }).body.force_encoding("UTF-8")
      lazy = body[/"id":"block-lazy","children":"([^"]*)"/, 1]
      say "- path restored before the block runs = #{off.nil?}: `t(\".lazy\")` inside the block → `#{lazy}`"
    end
  end
  say
end

# ---------------------------------------------------------------------------

wanted = ARGV.empty? ? SECTIONS.keys : ARGV
wanted.each { |name| SECTIONS.fetch(name).call }

if ARGV.empty?
  header = "# Story 19-0 — HTTP-level measurements\n\n" \
           "Written by `measure/measure.rb` on #{RUBY_DESCRIPTION}.\n\n"
  File.write(OUT, "#{header}#{REPORT.join("\n")}\n")
  puts "\nwrote #{OUT}"
end
FileUtils.rm_rf(TMP)
