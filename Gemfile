# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in ori.gemspec
gemspec

group :development do
  gem "sorbet", "~> 0.6.0"
  gem "rubocop-shopify", require: false
  gem "rubocop-sorbet", require: false
  gem "spoom", require: false
  gem "tapioca", require: false
  gem "rake", "~> 13.0"
end

group :test do
  gem "minitest", "~> 5.0"
end

group :development, :test do
  gem "debug", ">= 1.0.0", require: false
  gem "vernier", git: "https://github.com/jhawthorn/vernier.git"
end