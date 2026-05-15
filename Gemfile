# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in ruact.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

# Pin Rails version for CI matrix testing (RAILS_VERSION env var sets the version).
# When RAILS_VERSION is unset, default to Rails 8.0 so the Story 7.9 controller-request
# spec (Rails-8 view_context plumbing) can boot. Most other specs continue to use the
# minimal stub in spec/support/rails_stub.rb and never load Rails.
rails_version = ENV.fetch("RAILS_VERSION", "8.0")
gem "rails", "~> #{rails_version}"

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
# Re-run-4 (2026-05-15) — sqlite3 powers the AR-backed AC12 dispatch
# benchmark (`bench/server_functions_dispatch_bench.rb`) which compares
# `ruact_action :create_post` against a plain controller doing the same
# `Post.create!`. Not loaded by any spec; bench-only.
gem "sqlite3", "~> 2.1", require: false

# Coverage
gem "simplecov", "~> 0.22", require: false
gem "simplecov-lcov", "~> 0.8", require: false
