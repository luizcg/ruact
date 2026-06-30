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

Dir[File.join(__dir__, "support", "**", "*.rb")].each do |f|
  next if f.end_with?("_spec.rb") # spec files are loaded by the RSpec runner; avoid double registration

  require f
end

RSpec.configure do |config|
  config.order = :random
  config.expect_with :rspec do |expectations|
    expectations.max_formatted_output_length = 2000
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Story 7.3: Ruact.config is a frozen singleton with a boot-state flag for the
  # re-configuration warning. Reset both before every example so the boot flag
  # cannot leak between specs — otherwise the AC3 warning may fire into a
  # Rails.logger that has become a per-example RSpec double from an earlier
  # spec, producing "originally created in one example but has leaked" failures
  # under random order.
  config.before do
    Ruact.instance_variable_set(:@config, nil)
    Ruact.instance_variable_set(:@configured_at_least_once, false)
    # Story 9.3: specs that set `Rails.logger = instance_double(Logger)` (e.g.
    # railtie_spec, configuration_spec) leave a per-example double on the global
    # after they finish; rspec then refuses to call it from the NEXT example.
    # That was harmless until the codegen/rake paths began reading `Rails.logger`
    # (the `[ruact] codegen: exposing …` line). Reset it to a real, silent logger
    # before every example so no leaked double survives — examples that need a
    # specific logger set their own in their own `before` (which runs after this).
    Rails.logger = Logger.new(IO::NULL) if defined?(Rails) && Rails.respond_to?(:logger=)

    # Manifest-over-HTTP fix: the gem suite runs with `Rails.env == development`
    # by default, where `Ruact::ManifestResolver` would otherwise fetch the live
    # manifest from the Vite dev server (localhost:5173) on every ActionView
    # render — making the suite hit the network and go flaky on a dev machine
    # that happens to run a foreign Vite there. Pin the pre-fix behaviour (return
    # the boot-loaded `Ruact.manifest`) so the whole suite is hermetic. The
    # resolver's own spec re-stubs these `.and_call_original` to exercise the real
    # HTTP/fallback paths with `Net::HTTP` mocked. (The programmatic
    # `RenderPipeline#render({erb:})` path passes `registry: nil` and never
    # touches the resolver, so the benchmark measures the real render cost.)
    if defined?(Ruact::ManifestResolver)
      allow(Ruact::ManifestResolver).to receive(:resolve) { Ruact.manifest }
      allow(Ruact::ManifestResolver).to receive(:resolve_soft) { Ruact.manifest }
    end
  end
end
