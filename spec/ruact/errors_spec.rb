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
  end
end
