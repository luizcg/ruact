# frozen_string_literal: true

# A latch the test opens with a request of its own. Slow work in the
# experiment is `Gate.wait(name)`: it returns when the gate opens, never by
# time, so "the fallback was on screen before the work finished" is a fact about
# order and not about a sleep being long enough.
module Gate
  LIMIT = 60 # seconds; a gate nobody opens fails the run instead of hanging it

  @mutex = Mutex.new
  @cond = ConditionVariable.new
  @open = {}
  @waiting = Hash.new(0)

  class NeverOpened < StandardError; end

  def self.wait(name)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMIT
    @mutex.synchronize do
      @waiting[name] += 1
      begin
        until @open[name]
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise NeverOpened, "gate #{name} was never opened" if remaining <= 0

          @cond.wait(@mutex, remaining)
        end
      ensure
        @waiting[name] -= 1
      end
    end
    "open:#{name}"
  end

  def self.open(name)
    @mutex.synchronize do
      @open[name] = true
      @cond.broadcast
    end
  end

  def self.reset
    @mutex.synchronize do
      @open.clear
      @cond.broadcast
    end
  end

  # How many are blocked at each gate right now.
  def self.waiting
    @mutex.synchronize { @waiting.select { |_, count| count.positive? } }
  end
end
