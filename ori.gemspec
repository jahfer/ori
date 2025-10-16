# frozen_string_literal: true

require_relative "lib/ori/version"

Gem::Specification.new do |spec|
  spec.name = "ori-rb"
  spec.version = Ori::VERSION
  spec.authors = ["Jahfer Husain"]
  spec.email   = ["echo@jahfer.com"]
  spec.license = "MIT"

  spec.summary = "A library for building concurrent applications."
  spec.description = <<~DESC.gsub(/[[:space:]]+/, " ").strip
    Ori is a library for Ruby that provides a robust set of primitives
    for building concurrent applications.
    The name comes from the Japanese word 折り "ori" meaning "fold",
    reflecting how concurrent operations interleave.

    Ori provides a set of primitives that allow you to build concurrent
    applications—that is, applications that interleave execution within
    a single thread—without blocking the entire Ruby interpreter for
    each task.
  DESC
  spec.homepage = "https://github.com/jahfer/ori"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(["git", "ls-files", "-z"], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?("bin/", "test/", ".git", "Gemfile") ||
        f.end_with?(".gem")
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("nio4r", "~> 2.7")
  spec.add_dependency("sorbet", "~> 0.6.0")
  spec.add_dependency("zeitwerk", "~> 2.7.1")
end
