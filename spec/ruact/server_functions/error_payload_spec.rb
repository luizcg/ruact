# frozen_string_literal: true

require "spec_helper"
require "ruact/server_functions/error_payload"

module Ruact
  module ServerFunctions
    RSpec.describe ErrorPayload, :story_8_4 do
      let(:gem_root) { "/tmp/ruact-test-gem" }

      before { allow(Ruact).to receive(:gem_path).and_return(gem_root) }

      # Build an exception whose `.class.name` is spoofed so the spec can
      # exercise the RecordInvalid path without requiring ActiveRecord.
      def build_record_invalid(full_messages: ["Title can't be blank"])
        record = Object.new
        errors = Object.new
        record.define_singleton_method(:errors) { errors }
        errors.define_singleton_method(:full_messages) { full_messages }

        klass = Class.new(StandardError) do
          attr_reader :record
          define_singleton_method(:name) { "ActiveRecord::RecordInvalid" }
          def initialize(record, message)
            super(message)
            @record = record
          end
        end
        err = klass.new(record, "Validation failed: Title can't be blank")
        err.set_backtrace([
                            "/Users/dev/host/app/controllers/posts_controller.rb:12:in `create'",
                            "#{gem_root}/lib/ruact/server_functions/endpoint_controller.rb:111:in `dispatch'"
                          ])
        err
      end

      describe ".build in :development mode" do
        let(:error) { build_record_invalid }

        subject(:payload) do
          described_class.build(action_name: :create_post, error: error, mode: :development)
        end

        it "carries the discriminator" do
          expect(payload["_ruact_server_action_error"]).to be(true)
        end

        it "exposes the action name as a string (symbol input is coerced)" do
          expect(payload["action_name"]).to eq("create_post")
        end

        it "exposes the error class as a string" do
          expect(payload["error_class"]).to eq("ActiveRecord::RecordInvalid")
        end

        it "exposes the error message" do
          expect(payload["message"]).to eq("Validation failed: Title can't be blank")
        end

        it "splits the backtrace into app_frames and gem_frames" do
          expect(payload["app_frames"]).to contain_exactly(
            a_string_including("posts_controller.rb:12")
          )
          expect(payload["gem_frames"]).to contain_exactly(
            a_string_including("endpoint_controller.rb:111")
          )
        end

        it "extracts validation_errors from the record" do
          expect(payload["validation_errors"]).to eq(["Title can't be blank"])
        end

        it "extracts the contextual suggestion" do
          expect(payload["suggestion"]).to eq("Validation failed — check the model's `validates` rules")
        end
      end

      describe ".build in :production mode" do
        let(:error) { build_record_invalid }

        subject(:payload) do
          described_class.build(action_name: :create_post, error: error, mode: :production)
        end

        it "carries the four baseline keys" do
          expect(payload.keys).to contain_exactly(
            "_ruact_server_action_error",
            "action_name",
            "error_class",
            "message"
          )
        end

        it "shares the four baseline values with the dev-mode payload" do
          dev = described_class.build(action_name: :create_post, error: error, mode: :development)
          payload.each_key do |key|
            expect(payload[key]).to eq(dev[key])
          end
        end

        it "ABSENT (not null): app_frames, gem_frames, suggestion, validation_errors" do
          expect(payload).not_to have_key("app_frames")
          expect(payload).not_to have_key("gem_frames")
          expect(payload).not_to have_key("suggestion")
          expect(payload).not_to have_key("validation_errors")
        end
      end

      describe "validation_errors edge cases (dev mode)" do
        it "is [] when RecordInvalid was constructed without a record" do
          klass = Class.new(StandardError) do
            attr_reader :record
            define_singleton_method(:name) { "ActiveRecord::RecordInvalid" }
            def initialize
              super("boom")
              @record = nil
            end
          end
          payload = described_class.build(action_name: :x, error: klass.new, mode: :development)
          expect(payload["validation_errors"]).to eq([])
        end

        it "is ABSENT (no key) when the error class is not RecordInvalid" do
          payload = described_class.build(
            action_name: :x,
            error: RuntimeError.new("boom"),
            mode: :development
          )
          expect(payload).not_to have_key("validation_errors")
        end
      end

      describe "suggestion is null for unknown error classes (dev mode)" do
        it "produces suggestion: nil for RuntimeError" do
          payload = described_class.build(
            action_name: :x,
            error: RuntimeError.new("boom"),
            mode: :development
          )
          expect(payload["suggestion"]).to be_nil
        end
      end

      describe "Pitfall #5 — frozen-string error message safety" do
        it "does not raise FrozenError when the error message is frozen" do
          err = StandardError.new("frozen msg".freeze)
          expect do
            described_class.build(action_name: :x, error: err, mode: :development)
          end.not_to raise_error
        end

        it "stores a mutable dup of the message in the payload" do
          err = StandardError.new("frozen msg".freeze)
          payload = described_class.build(action_name: :x, error: err, mode: :development)
          expect(payload["message"]).to eq("frozen msg")
          expect(payload["message"]).not_to be_frozen
        end
      end

      describe "backtrace edge cases (dev mode)" do
        it "is { app_frames: [], gem_frames: [] } when backtrace is nil" do
          err = StandardError.new("boom") # never raised => backtrace is nil
          payload = described_class.build(action_name: :x, error: err, mode: :development)
          expect(payload["app_frames"]).to eq([])
          expect(payload["gem_frames"]).to eq([])
        end

        it "caps each bucket at MAX_FRAMES_PER_BUCKET frames" do
          app_frames = Array.new(40) { |i| "/Users/dev/host/app/file_#{i}.rb:#{i}" }
          gem_frames = Array.new(40) { |i| "#{gem_root}/lib/ruact/file_#{i}.rb:#{i}" }
          err = StandardError.new("boom")
          err.set_backtrace(app_frames + gem_frames)
          payload = described_class.build(action_name: :x, error: err, mode: :development)
          expect(payload["app_frames"].size).to eq(ErrorPayload::MAX_FRAMES_PER_BUCKET)
          expect(payload["gem_frames"].size).to eq(ErrorPayload::MAX_FRAMES_PER_BUCKET)
        end
      end
    end
  end
end
