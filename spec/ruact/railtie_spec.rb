# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "logger"
require "socket"

# The Rails stub is provided by spec/support/rails_stub.rb.
# We explicitly require the railtie here (was skipped in ruact.rb because
# Rails was not defined when that file loaded).
require "ruact/railtie"

RSpec.describe Ruact::Railtie do
  let(:missing_path) { Pathname.new("/nonexistent/path/react-client-manifest.json") }
  let(:fake_logger) { instance_double(Logger, warn: nil, info: nil) }

  before do
    Rails.logger = fake_logger
  end

  describe ".detect_streaming_mode! (AC#1–3)" do
    after { Ruact.streaming_mode = nil }

    context "when Puma is defined" do
      before do
        puma = Module.new { const_set(:Server, Class.new) }
        stub_const("Puma", puma)
      end

      it "sets streaming_mode to :enabled" do
        described_class.detect_streaming_mode!
        expect(Ruact.streaming_mode).to eq(:enabled)
      end

      it "logs streaming: enabled (Puma detected)" do
        described_class.detect_streaming_mode!
        expect(fake_logger).to have_received(:info)
          .with(a_string_including("streaming: enabled (Puma detected)"))
      end
    end

    context "when Unicorn is defined" do
      before { stub_const("Unicorn", Module.new) }

      it "sets streaming_mode to :buffered" do
        described_class.detect_streaming_mode!
        expect(Ruact.streaming_mode).to eq(:buffered)
      end

      it "logs streaming: buffered (Unicorn detected)" do
        described_class.detect_streaming_mode!
        expect(fake_logger).to have_received(:info)
          .with(a_string_including("streaming: buffered (Unicorn detected)"))
      end
    end

    context "when PhusionPassenger is defined" do
      before { stub_const("PhusionPassenger", Module.new) }

      it "sets streaming_mode to :buffered" do
        described_class.detect_streaming_mode!
        expect(Ruact.streaming_mode).to eq(:buffered)
      end

      it "logs streaming: buffered (Passenger detected)" do
        described_class.detect_streaming_mode!
        expect(fake_logger).to have_received(:info)
          .with(a_string_including("streaming: buffered (Passenger detected)"))
      end
    end

    context "when no recognized server constant is defined" do
      it "sets streaming_mode to :buffered" do
        described_class.detect_streaming_mode!
        expect(Ruact.streaming_mode).to eq(:buffered)
      end

      it "logs server unknown — defaulting to safe mode" do
        described_class.detect_streaming_mode!
        expect(fake_logger).to have_received(:info)
          .with(a_string_including("server unknown — defaulting to safe mode"))
      end
    end
  end

  describe ".check_manifest!" do
    context "with missing manifest in development (AC#5, #7)" do
      before do
        Rails.env = ActiveSupport::StringInquirer.new("development")
      end

      it "does not raise" do
        expect { described_class.check_manifest!(missing_path) }.not_to raise_error
      end

      it "logs a [ruact] prefixed warning" do
        described_class.check_manifest!(missing_path)
        expect(fake_logger).to have_received(:warn)
          .with(a_string_starting_with("[ruact]"))
      end

      it "includes the manifest path in the warning" do
        described_class.check_manifest!(missing_path)
        expect(fake_logger).to have_received(:warn)
          .with(a_string_including(missing_path.to_s))
      end
    end

    context "with missing manifest in production (AC#6)" do
      before do
        Rails.env = ActiveSupport::StringInquirer.new("production")
      end

      it "raises ManifestError" do
        expect { described_class.check_manifest!(missing_path) }
          .to raise_error(Ruact::ManifestError)
      end

      it "error message contains 'run vite build before deploying'" do
        expect { described_class.check_manifest!(missing_path) }
          .to raise_error(Ruact::ManifestError, /run vite build before deploying/)
      end
    end
  end

  describe ".check_vite!" do
    context "when Vite is running (AC#4)" do
      before do
        allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
      end

      it "does not log a warning" do
        described_class.check_vite!
        expect(fake_logger).not_to have_received(:warn)
      end
    end

    context "when Vite is not running (AC#4)" do
      before do
        allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
      end

      it "logs a [ruact] prefixed warning" do
        described_class.check_vite!
        expect(fake_logger).to have_received(:warn)
          .with(a_string_starting_with("[ruact]"))
      end

      it "mentions Vite and port 5173" do
        described_class.check_vite!
        expect(fake_logger).to have_received(:warn)
          .with(a_string_including("localhost:5173"))
      end
    end
  end
end
