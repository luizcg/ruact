# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe "Error classes" do
    describe "Ruact::Error" do
      it "is a subclass of StandardError" do
        expect(Error.ancestors).to include(StandardError)
      end
    end

    describe "Ruact::ManifestError" do
      it "is a subclass of Ruact::Error" do
        expect(ManifestError.ancestors).to include(Error)
      end

      it "can be raised and rescued as Ruact::Error" do
        expect { raise ManifestError, "test" }.to raise_error(Error)
      end
    end

    describe "Ruact::SerializationError" do
      it "is a subclass of Ruact::Error" do
        expect(SerializationError.ancestors).to include(Error)
      end

      it "can be raised and rescued as Ruact::Error" do
        expect { raise SerializationError, "test" }.to raise_error(Error)
      end
    end

    describe "Ruact::PreprocessorError" do
      it "is a subclass of Ruact::Error" do
        expect(PreprocessorError.ancestors).to include(Error)
      end

      it "can be raised and rescued as Ruact::Error" do
        expect { raise PreprocessorError, "test" }.to raise_error(Error)
      end
    end

    describe "Ruact::ConfigurationError" do
      it "is a subclass of Ruact::Error" do
        expect(ConfigurationError.ancestors).to include(Error)
      end

      it "can be raised and rescued as Ruact::Error" do
        expect { raise ConfigurationError, "test" }.to raise_error(Error)
      end
    end

    describe "Ruact::HtmlConverterError" do
      it "is a subclass of Ruact::Error" do
        expect(HtmlConverterError.ancestors).to include(Error)
      end

      it "can be raised and rescued as Ruact::Error" do
        expect { raise HtmlConverterError, "test" }.to raise_error(Error)
      end
    end

    describe "Ruact::UploadTooLargeError", :story_8_5 do
      it "is a subclass of Ruact::Error (so Story 8.4 rescue_from StandardError catches it)" do
        expect(UploadTooLargeError.ancestors).to include(Error)
      end

      it "carries received_bytes and limit_bytes attr_readers" do
        error = UploadTooLargeError.new(received_bytes: 11_534_336, limit_bytes: 10_485_760)
        expect(error.received_bytes).to eq(11_534_336)
        expect(error.limit_bytes).to eq(10_485_760)
      end

      it "synthesises a default message that includes both numbers" do
        error = UploadTooLargeError.new(received_bytes: 11_534_336, limit_bytes: 10_485_760)
        expect(error.message).to include("received_bytes=11534336")
        expect(error.message).to include("limit_bytes=10485760")
      end

      it "honours an explicit custom message" do
        error = UploadTooLargeError.new(received_bytes: 1, limit_bytes: 2, message: "custom")
        expect(error.message).to eq("custom")
      end

      it "can be rescued as Ruact::Error and StandardError" do
        expect { raise UploadTooLargeError.new(received_bytes: 1, limit_bytes: 0) }
          .to raise_error(Error)
        expect { raise UploadTooLargeError.new(received_bytes: 1, limit_bytes: 0) }
          .to raise_error(StandardError)
      end
    end
  end
end
