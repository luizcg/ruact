# frozen_string_literal: true

require "simplecov"
require "simplecov-lcov"

SimpleCov::Formatter::LcovFormatter.config do |c|
  c.report_with_single_file = true
  c.single_report_path = "coverage/lcov.info"
end

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :line
  formatter SimpleCov::Formatter::MultiFormatter.new(
    [
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::LcovFormatter
    ]
  )
  add_filter %r{^/spec/}
  add_filter %r{^/bin/}
  add_filter %r{lib/generators/.+/templates/}
  add_filter "lib/ruact/version.rb"
end

require "logger"
require "ruact"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.order = :random
  config.expect_with :rspec do |expectations|
    expectations.max_formatted_output_length = 2000
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
