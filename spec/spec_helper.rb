# frozen_string_literal: true

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
