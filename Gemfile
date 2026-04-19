# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in rails_rsc.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

# Pin Rails version for CI matrix testing (RAILS_VERSION env var sets the version).
# When RAILS_VERSION is unset, specs run against rails_stub in spec/support/rails_stub.rb.
rails_version = ENV.fetch("RAILS_VERSION", nil)
gem "rails", "~> #{rails_version}" if rails_version

# Testing
gem "rspec", "~> 3.13"
gem "rspec-benchmark", "~> 0.6"

# Linting
gem "rubocop", "~> 1.65", require: false
gem "rubocop-performance", "~> 1.21", require: false
gem "rubocop-rails", "~> 2.25", require: false
gem "rubocop-rspec", "~> 3.0", require: false

# Documentation
gem "yard", "~> 0.9", require: false

# Benchmarking
gem "benchmark-ips", "~> 2.14", require: false
gem "memory_profiler", "~> 1.0", require: false
