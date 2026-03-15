# typed: false
# frozen_string_literal: true

require_relative "../../lib/ori"

# Manages a voxtral STT subprocess, providing separate IO streams for
# transcript data (stdout) and status messages (stderr).
class VoxtralProcess
  VOXTRAL_BIN = "/Users/jahfer/src/github.com/antirez/voxtral.c/voxtral"
  VOXTRAL_MODEL = "/Users/jahfer/src/github.com/antirez/voxtral.c/voxtral-model"

  attr_reader :transcript_io, :status_io

  STATUS_PATTERN = /loading|loaded|listening|stopping|error|warning/i

  def initialize(interval: 1.0)
    @transcript_io, transcript_writer = IO.pipe
    @status_io, status_writer = IO.pipe
    stdout_reader, stdout_writer = IO.pipe

    @thread = Thread.new do
      @pid = Process.spawn(
        VOXTRAL_BIN,
        "-d",
        VOXTRAL_MODEL,
        "--from-mic",
        "--silent",
        "-I",
        interval.to_s,
        out: stdout_writer,
        err: status_writer,
      )
      stdout_writer.close
      status_writer.close

      loop do
        transcript_writer.write(stdout_reader.readpartial(4096))
        transcript_writer.flush
      rescue EOFError
        break
      end

      Process.wait(@pid)
    ensure
      transcript_writer.close
      stdout_reader.close unless stdout_reader.closed?
      stdout_writer.close unless stdout_writer.closed?
      status_writer.close unless status_writer.closed?
    end
  end

  def join = @thread.join

  def close
    @transcript_io.close unless @transcript_io.closed?
    @status_io.close unless @status_io.closed?
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

  # Monitor voxtral's stderr for status updates (via readpartial, not gets)
  scope.fork do
    buf = +""
    loop do
      buf << voxtral.status_io.readpartial(4096)

      while (idx = buf.index("\n"))
        line = buf.slice!(0, idx + 1).strip
        $stderr.puts "[voxtral] #{line}" if line.match?(VoxtralProcess::STATUS_PATTERN)
      end
    rescue EOFError
      line = buf.strip
      $stderr.puts "[voxtral] #{line}" if !line.empty? && line.match?(VoxtralProcess::STATUS_PATTERN)
      break
    end
  end

  # Read transcript chunks, split into sentences, push to channel
  scope.fork do
    SentenceTokenizer.new(voxtral.transcript_io).each_sentence do |sentence|
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
end

voxtral.close
voxtral.join
