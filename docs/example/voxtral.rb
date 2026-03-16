# typed: false
# frozen_string_literal: true

require_relative "../../lib/ori"

# Manages a voxtral STT subprocess. With io_read/io_write/process_wait
# implemented in the scheduler, we can spawn directly and hand the raw
# IO pipes to Ori fibers — no bridge thread needed.
class VoxtralProcess
  VOXTRAL_BIN = "/Users/jahfer/src/github.com/antirez/voxtral.c/voxtral"
  VOXTRAL_MODEL = "/Users/jahfer/src/github.com/antirez/voxtral.c/voxtral-model"

  attr_reader :stdout_io, :stderr_io, :pid

  STATUS_PATTERN = /loading|loaded|listening|stopping|error|warning/i

  def initialize(interval: 1.0)
    @stdout_io, stdout_writer = IO.pipe
    @stderr_io, stderr_writer = IO.pipe

    @pid = Process.spawn(
      VOXTRAL_BIN,
      "-d",
      VOXTRAL_MODEL,
      "--from-mic",
      "--silent",
      "-I",
      interval.to_s,
      out: stdout_writer,
      err: stderr_writer,
    )

    stdout_writer.close
    stderr_writer.close
  end

  def close
    @stdout_io.close unless @stdout_io.closed?
    @stderr_io.close unless @stderr_io.closed?
  end
end

# Reads chunks from an IO and yields complete sentences (delimited by
# sentence-ending punctuation). Leftover text is yielded on EOF.
class SentenceTokenizer
  SENTENCE_END = /\A(.*?[.!?])(.*)\z/m

  def initialize(io)
    @io = io
  end

  def each_sentence
    buf = +""
    loop do
      buf << @io.readpartial(4096)
      print(".")

      while (match = buf.match(SENTENCE_END))
        puts ""
        sentence = match[1].strip
        buf = match[2]
        yield sentence unless sentence.empty?
      end
    rescue EOFError
      yield buf.strip unless buf.strip.empty?
      break
    end
  end
end

# --- Main ---

$stdout.sync = true

voxtral = VoxtralProcess.new(interval: 1.0)

Ori.sync do |scope|
  transcript = Ori::Channel.new(100)

  # Monitor voxtral's stderr for status updates
  scope.fork do
    voxtral.stderr_io.each_line do |line|
      $stderr.puts "[voxtral] #{line.strip}" if line.match?(VoxtralProcess::STATUS_PATTERN)
    end
  end

  # Read transcript chunks, split into sentences, push to channel
  scope.fork do
    SentenceTokenizer.new(voxtral.stdout_io).each_sentence do |sentence|
      transcript << sentence
    end
  end

  # Consume sentences and print title-cased
  scope.fork do
    loop do
      sentence = transcript.take
      puts "Original: #{sentence}"
      puts sentence.split.map { |w| w == w.upcase ? w : w.capitalize }.join(" ")
    end
  end

  # Wait for the voxtral process to exit (non-blocking via process_wait)
  scope.fork do
    Process.wait(voxtral.pid)
  end
end

voxtral.close
