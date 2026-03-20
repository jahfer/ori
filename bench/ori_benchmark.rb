#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "ori"
require "benchmark"

# Number of iterations for each sub-benchmark
N = Integer(ENV.fetch("BENCH_N", 200))
FIBERS = Integer(ENV.fetch("BENCH_FIBERS", 50))
CHANNEL_MSGS = Integer(ENV.fetch("BENCH_MSGS", 100))

results = {}

# 1. Fork/join: create many fibers that do trivial work
results[:fork_join] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      FIBERS.times do |i|
        scope.fork { i * 2 }
      end
    end
  end
end

# 2. Channel throughput: producer/consumer through buffered channel
results[:channel] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      ch = Ori::Channel.new(10)
      scope.fork do
        CHANNEL_MSGS.times { |i| ch.put(i) }
      end
      scope.fork do
        CHANNEL_MSGS.times { ch.take }
      end
    end
  end
end

# 3. Promise resolution: many fibers waiting on promises
results[:promise] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      promises = Array.new(FIBERS) { Ori::Promise.new }
      promises.each do |p|
        scope.fork { p.await }
      end
      scope.fork do
        promises.each_with_index { |p, i| p.resolve(i) }
      end
    end
  end
end

# 4. Semaphore contention: many fibers competing for limited resource
results[:semaphore] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      sem = Ori::Semaphore.new(3)
      FIBERS.times do
        scope.fork do
          sem.sync { :work }
        end
      end
    end
  end
end

# 5. Broadcast: publisher with multiple subscribers
results[:broadcast] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      bc = Ori::Broadcast.new
      subs = Array.new(10) { bc.subscribe }
      subs.each do |sub|
        scope.fork { 5.times { sub.take } }
      end
      scope.fork do
        5.times { |i| bc.publish(i) }
      end
    end
  end
end

# 6. Select: race between multiple channels
results[:select] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      ch1 = Ori::Channel.new(1)
      ch2 = Ori::Channel.new(1)
      scope.fork { ch1.put(:a) }
      scope.fork { ch2.put(:b) }
      scope.fork { Ori.select([ch1, ch2]) }
    end
  end
end

# 7. Nested scopes: scope-within-scope overhead
results[:nested_scopes] = Benchmark.realtime do
  N.times do
    Ori.sync do |outer|
      3.times do
        outer.fork do
          Ori.sync do |inner|
            10.times { |i| inner.fork { i } }
          end
        end
      end
    end
  end
end

# 8. Mixed workload: channels + promises + semaphores together
results[:mixed] = Benchmark.realtime do
  N.times do
    Ori.sync do |scope|
      ch = Ori::Channel.new(5)
      sem = Ori::Semaphore.new(2)
      promise = Ori::Promise.new

      scope.fork do
        20.times { |i| ch.put(i) }
        promise.resolve(:done)
      end

      5.times do
        scope.fork do
          sem.sync do
            4.times { ch.take }
          end
        end
      end

      scope.fork { promise.await }
    end
  end
end

total_seconds = results.values.sum
total_ops = N * results.size # each sub-benchmark runs N iterations
ops_per_sec = (total_ops / total_seconds).round(1)

# Output METRIC lines
puts "METRIC ops_per_sec=#{ops_per_sec}"
puts "METRIC total_ms=#{(total_seconds * 1000).round(1)}"
results.each do |name, time|
  puts "METRIC #{name}_ms=#{(time * 1000).round(1)}"
end
