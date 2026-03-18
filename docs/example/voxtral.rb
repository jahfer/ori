# typed: false
# frozen_string_literal: true

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gemspec
  gem "ruby_llm"
end

require_relative "../../lib/ori"

# Manages a voxtral STT subprocess. With io_read/io_write/process_wait
# implemented in the scheduler, we can spawn directly and hand the raw
# IO pipes to Ori fibers — no bridge thread needed.
class VoxtralProcess
  VOXTRAL_BIN = File.expand_path("~/src/github.com/antirez/voxtral.c/voxtral")
  VOXTRAL_MODEL = File.expand_path("~/src/github.com/antirez/voxtral.c/voxtral-model")

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
      # "--silent",
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

class WakeWordDetector
  WAKE_WORDS = ["oris"]

  def initialize(input_io)
    @input_io = input_io
  end

  # Reads raw process IO and manages session lifecycle. On wake word detection,
  # creates a fresh session channel, hands it to the tokenizer via
  # activation_channel (rendezvous), then forwards subsequent chunks to it.
  # Transitions back to WAITING when done_channel carries the idle-timeout signal.
  def run(activation_channel, done_channel)
    buffer = +""
    active = false
    session_channel = nil

    loop do
      if active && done_channel.value?
        done_channel.take
        active = false
        session_channel = nil
        buffer = +""
        $stderr.puts "[wake] idle timeout — listening for wake word..."
      end

      chunk = @input_io.readpartial(1024)

      if active
        session_channel << chunk
      else
        buffer << chunk
        WAKE_WORDS.each do |wake_word|
          if buffer.downcase.include?(wake_word)
            $stderr.puts "[wake] wake word '#{wake_word}' detected — activating session"
            active = true
            buffer = +""
            session_channel = Ori::Channel.new(100)
            activation_channel << session_channel  # rendezvous: blocks until tokenizer is ready
            break
          end
        end
      end
    rescue EOFError
      break
    end
  end
end

# Waits for wake word activation, then accumulates text from the per-session
# channel into complete sentences. If no sentence is captured within
# IDLE_TIMEOUT seconds, flushes remaining text and signals done so
# WakeWordDetector can resume responsibility for the next activation.
class SentenceTokenizer
  SENTENCE_END = /\A(.*?[.!?])(.*)\z/m
  IDLE_TIMEOUT = 10.0

  def run(activation_channel, done_channel, sentences_channel)
    loop do
      session_channel = activation_channel.take

      buf = +""
      last_sentence_at = Time.now

      loop do
        remaining = IDLE_TIMEOUT - (Time.now - last_sentence_at)
        if remaining <= 0
          $stderr.puts "[tokenizer] idle timeout — flushing"
          flush(buf, sentences_channel)
          done_channel << true
          break
        end

        winner = Ori::Select.await([session_channel, Ori::Timeout.new(remaining)])
        case winner
        when session_channel
          buf << session_channel.take
          while (match = buf.match(SENTENCE_END))
            sentence = match[1].strip
            buf = match[2]
            unless sentence.empty?
              $stderr.puts "[tokenizer] sentence: #{sentence.inspect}"
              sentences_channel << sentence
              last_sentence_at = Time.now
            end
          end
        when Ori::Timeout
          $stderr.puts "[tokenizer] idle timeout — flushing"
          flush(buf, sentences_channel)
          done_channel << true
          break
        end
      end
    end
  end

  private

  def flush(buf, sentences_channel)
    text = buf.strip
    sentences_channel << text unless text.empty?
  end
end

# --- Main ---

$stdout.sync = true

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["API_PROXY_KEY"]
  config.anthropic_api_base = ENV.fetch("API_PROXY_URL")
end

chat = RubyLLM.chat(model: "claude-haiku-4-5")
voxtral = VoxtralProcess.new(interval: 1.0)
ready = Ori::Promise.new

Ori.sync do |scope|
  # activation_channel: zero-sized rendezvous — each wake word detection sends
  # a fresh session channel, blocking until SentenceTokenizer is ready to receive.
  activation_channel = Ori::Channel.new(0)
  # done_channel: buffered(1) so the tokenizer never blocks signalling idle timeout.
  done_channel = Ori::Channel.new(1)
  sentences = Ori::Channel.new(100)
  processed_transcript = []
  transcript_buffer = []
  transcript_lock = Ori::Mutex.new

  # Monitor voxtral's stderr for status updates
  scope.fork do
    voxtral.stderr_io.each_line do |line|
      $stderr.puts "[voxtral] #{line.strip}" if line.match?(VoxtralProcess::STATUS_PATTERN)

      ready.resolve(true) if line.include?("Listening")
    end
  end

  # WakeWordDetector listens to raw process IO; on wake word it hands a fresh
  # session channel to the tokenizer and forwards subsequent chunks to it.
  scope.fork do
    WakeWordDetector.new(voxtral.stdout_io).run(activation_channel, done_channel)
  end

  # SentenceTokenizer awakens on activation, accumulates sentences, and
  # flushes/terminates after 10s without a new sentence.
  scope.fork do
    SentenceTokenizer.new.run(activation_channel, done_channel, sentences)
  end

  # Consume sentences into transcript buffer
  scope.fork do
    loop do
      ready.await
      sentence = sentences.take
      transcript_lock.sync { transcript_buffer << sentence }
    end
  end

  scope.fork do
    loop do
      ready.await
      sleep(15)
      next if transcript_buffer.empty?

      new_text = ""

      processed_text = processed_transcript.join(" ")
      transcript_lock.sync do
        new_text = transcript_buffer.join(" ")

        processed_transcript.concat(transcript_buffer)
        transcript_buffer.clear
      end

      msg = <<~MSG
        Summarize the following transcript.
        
        ## Transcript so far:
        #{processed_text}

        ## New transcript since last summary:
        #{new_text}
      MSG

      puts msg

      response = chat.ask(msg)
      puts response.content
      puts "-" * 40
    end
  end

  # Wait for the voxtral process to exit (non-blocking via process_wait)
  scope.fork do
    Process.wait(voxtral.pid)
  end
end

voxtral.close
