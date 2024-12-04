# frozen_string_literal: true

require_relative "lib/ori/version"

Gem::Specification.new do |spec|
  spec.name = "shopify-ori"
  spec.version = Ori::VERSION
  spec.authors = ["Shopify Engineering"]
  spec.email   = ["gems@shopify.com"]

  spec.summary = "Ori is a library for building concurrent applications."
  spec.description = spec.summary
  spec.homepage = "https://github.com/Shopify/ori"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://pkgs.shopify.io"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(["git", "ls-files", "-z"], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?("bin/", "test/", ".git", "Gemfile")
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("nio4r", "~> 2.7")
  spec.add_dependency("sorbet-runtime")
  spec.add_dependency("zeitwerk", "~> 2.7.1")
end
