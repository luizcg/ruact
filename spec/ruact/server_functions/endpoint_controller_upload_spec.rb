# frozen_string_literal: true

# Story 8.5 — request-cycle spec for file uploads through
# POST /__ruact/fn/:name. Asserts that:
#   - controller-hosted and standalone-hosted actions both receive multipart
#     file fields as ActionDispatch::Http::UploadedFile (AC1)
#   - mixed file + non-file fields are preserved on both branches (AC4)
#   - Ruact.config.max_upload_bytes pre-parse guard returns 413 + the Story
#     8.4 structured `_ruact_server_action_error` body with the new
#     dev-only `upload_limit` block (AC3)
#   - chunked-transfer requests (no Content-Length) bypass the guard
#     (Pitfall #1)
#   - application/json requests bypass the guard (Pitfall #12)
#   - the size check fires BEFORE CSRF on the standalone branch — oversized
#     no-token request returns 413, not 403 (Pitfall #4)
#   - Ruact.config.max_upload_bytes = nil disables the guard entirely
#
# Reuses the Story 8.1 `dispatch_request_spec.rb` shared Rails::Application
# (the `routes.append` that draws POST /__ruact/fn/:name is performed at
# load time inside that file). Registering upload actions on the existing
# TestController + a fresh standalone host module avoids duplicating the
# Rails app boot cost.

require_relative "dispatch_request_spec"

# Top-level constants + standalone host module: Rails' route resolver and
# the action registry both store references by Module identity, so the host
# must be defined at top-level (matching dispatch_request_spec.rb's
# DispatchRequestSpecSupport pattern). The constants are siblings so the
# RSpec describe block does NOT trigger Lint/ConstantDefinitionInBlock /
# RSpec/LeakyConstantDeclaration.
UPLOAD_SPEC_FIXTURE_PNG_PATH =
  File.expand_path("../../support/fixtures/pixel.png", __dir__).freeze
UPLOAD_SPEC_FIXTURE_PNG_BYTES = File.binread(UPLOAD_SPEC_FIXTURE_PNG_PATH).freeze

module UploadSpecStandaloneHost
  extend Ruact::ServerAction
end

RSpec.describe "Story 8.5 — file upload via server action", :story_8_5 do
  include Rack::Test::Methods

  let(:app_class) { DispatchRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  before do
    Rails.logger = Logger.new(IO::NULL)
    DispatchRequestSpecSupport.boot!
    # Re-register the dispatch-spec's standard actions so unrelated suite
    # state survives this file's nested setup (registry is reset between
    # examples via spec_helper).
    DispatchRequestSpecSupport::TestController.register_ruact_actions!

    # Story 8.5 — register the upload-specific actions on the SAME
    # controller. Re-registers per-example because the action_registry is
    # a lazy-init singleton reset between examples (spec_helper).
    DispatchRequestSpecSupport::TestController.ruact_action(:upload_post) do |params|
      uploaded = params[:cover]
      {
        "title" => params[:title].to_s,
        "published" => params[:published].to_s,
        "uploaded_class" => uploaded.class.name,
        "original_filename" => uploaded&.original_filename,
        "content_type" => uploaded&.content_type,
        "byte_size" => uploaded&.read&.bytesize
      }
    end

    UploadSpecStandaloneHost.module_eval do
      ruact_action(:upload_standalone) do |params|
        uploaded = params[:doc]
        {
          "title" => params[:title].to_s,
          "uploaded_class" => uploaded.class.name,
          "original_filename" => uploaded&.original_filename,
          "byte_size" => uploaded&.read&.bytesize
        }
      end
    end
  end

  describe "AC1 — controller-hosted action receives ActionDispatch::Http::UploadedFile" do
    it "params[:cover] arrives as ActionDispatch::Http::UploadedFile with correct metadata" do
      post "/__ruact/fn/upload_post",
           {
             "title" => "My Post",
             "published" => "true",
             "cover" => Rack::Test::UploadedFile.new(UPLOAD_SPEC_FIXTURE_PNG_PATH, "image/png")
           }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
      expect(body.fetch("original_filename")).to eq("pixel.png")
      expect(body.fetch("content_type")).to eq("image/png")
      expect(body.fetch("byte_size")).to eq(UPLOAD_SPEC_FIXTURE_PNG_BYTES.bytesize)
    end
  end

  describe "AC1 — standalone-hosted action receives ActionDispatch::Http::UploadedFile" do
    # Standalone branch defaults to allow_forgery_protection = false here so
    # the upload exercises dispatch mechanics without the CSRF callback.
    # The CSRF-order Pitfall #4 spec below flips this on explicitly.
    around do |example|
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    it "params[:doc] arrives as ActionDispatch::Http::UploadedFile on the standalone branch" do
      post "/__ruact/fn/upload_standalone",
           {
             "title" => "Standalone Upload",
             "doc" => Rack::Test::UploadedFile.new(UPLOAD_SPEC_FIXTURE_PNG_PATH, "image/png")
           }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
      expect(body.fetch("original_filename")).to eq("pixel.png")
      expect(body.fetch("byte_size")).to eq(UPLOAD_SPEC_FIXTURE_PNG_BYTES.bytesize)
    end
  end

  describe "AC4 — mixed file + non-file fields are both preserved" do
    it "non-file fields arrive as UTF-8 strings; file field arrives as UploadedFile" do
      post "/__ruact/fn/upload_post",
           {
             "title" => "My Post",
             "published" => "true",
             "cover" => Rack::Test::UploadedFile.new(UPLOAD_SPEC_FIXTURE_PNG_PATH, "image/png")
           }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      # Non-file fields: UTF-8 strings, no Boolean/Integer coercion (the
      # host is responsible for casting; the multipart switch itself does
      # NOT destroy the field).
      expect(body.fetch("title")).to eq("My Post")
      expect(body.fetch("published")).to eq("true")
      # File field: UploadedFile, not absent, not coerced to a String.
      expect(body.fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
    end
  end

  describe "AC3 — oversized multipart request returns 413 + structured body" do
    before do
      # spec_helper's global before-hook resets @config to nil at the start of
      # every example; that runs AFTER an `around` would set up state, so the
      # tight 1 KB cap is set here (after the global reset, after the
      # describe-level boot/registration `before`) so it sticks for the
      # example body.
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = 1024 } # 1 KB cap for the test
    end

    it "controller-hosted: oversized multipart upload → 413 with _ruact_server_action_error + upload_limit" do
      # The 70-byte pixel.png plus boundary overhead still fits under 1 KB,
      # so synthesize a larger blob in-memory via Rack::Test::UploadedFile
      # on a tmp file.
      large = Tempfile.new(["big", ".bin"])
      large.binmode
      large.write("x" * 4096) # 4 KB > 1 KB limit
      large.rewind

      post "/__ruact/fn/upload_post",
           {
             "title" => "Too big",
             "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
           }
      expect(last_response.status).to eq(413)
      body = JSON.parse(last_response.body)
      expect(body).to include(
        "_ruact_server_action_error" => true,
        "error_class" => "Ruact::UploadTooLargeError",
        "action_name" => "upload_post"
      )
      expect(body.fetch("upload_limit")).to include("limit_bytes" => 1024)
      expect(body.fetch("upload_limit").fetch("received_bytes")).to be > 4096
    ensure
      large.close
      large.unlink
    end

    it "standalone: oversized multipart upload → 413 with structured body (same shape)" do
      previous_forgery = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false
      large = Tempfile.new(["big", ".bin"])
      large.binmode
      large.write("x" * 4096)
      large.rewind

      post "/__ruact/fn/upload_standalone",
           {
             "title" => "Too big",
             "doc" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
           }
      expect(last_response.status).to eq(413)
      body = JSON.parse(last_response.body)
      expect(body.fetch("_ruact_server_action_error")).to be(true)
      expect(body.fetch("error_class")).to eq("Ruact::UploadTooLargeError")
      expect(body.fetch("action_name")).to eq("upload_standalone")
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous_forgery
      large.close
      large.unlink
    end
  end

  describe "Pitfall #4 — guard fires BEFORE CSRF for standalone branch" do
    around do |example|
      previous_forgery = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = true
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous_forgery
    end

    before do
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = 1024 }
    end

    it "oversized standalone request WITHOUT CSRF token returns 413, not 403" do
      large = Tempfile.new(["big", ".bin"])
      large.binmode
      large.write("x" * 4096)
      large.rewind

      post "/__ruact/fn/upload_standalone",
           {
             "title" => "Too big, no token",
             "doc" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
           }
      expect(last_response.status).to eq(413)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error_class")).to eq("Ruact::UploadTooLargeError")
    ensure
      large.close
      large.unlink
    end
  end

  describe "AC3 — max_upload_bytes = nil disables the gem-side guard" do
    before do
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = nil }
    end

    it "request body of any size flows through to the action body" do
      # 4 KB blob — would have been rejected under the 1 KB test cap above
      # but max_upload_bytes is now nil, so the request reaches the action.
      large = Tempfile.new(["big", ".bin"])
      large.binmode
      large.write("x" * 4096)
      large.rewind

      post "/__ruact/fn/upload_post",
           {
             "title" => "no cap",
             "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
           }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
    ensure
      large.close
      large.unlink
    end
  end

  describe "Pitfall #12 — application/json bypasses the upload guard" do
    before do
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = 1024 } # 1 KB cap
    end

    it "a 4 KB JSON body passes the guard (content type is not multipart/urlencoded)" do
      # JSON bigger than the 1 KB cap — must NOT trigger the upload guard
      # because the guard is gated by content type. The body still reaches
      # the :echo action which echoes the payload back.
      payload = { "blob" => "x" * 4096 }
      post "/__ruact/fn/echo", payload.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("echoed").fetch("blob").length).to eq(4096)
    end
  end

  # Unit-level coverage of __ruact_enforce_upload_limit! — exercises the
  # short-circuit branches (nil limit, nil Content-Length, non-multipart
  # content type) directly against the controller instance. The
  # request-cycle specs above cover the raise path; these specs cover the
  # bypass paths without paying for a full multipart request.
  describe "Unit — __ruact_enforce_upload_limit! short-circuits" do
    let(:controller) { Ruact::ServerFunctions::EndpointController.new }

    def with_max_upload_bytes(value)
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
      Ruact.configure { |c| c.max_upload_bytes = value }
      yield
    ensure
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
    end

    def stub_request(content_type:, content_length:)
      request = instance_double(ActionDispatch::Request, content_length: content_length)
      allow(request).to receive(:content_mime_type)
        .and_return(content_type ? Mime::Type.lookup(content_type) : nil)
      allow(controller).to receive(:request).and_return(request)
    end

    it "Pitfall #1 — nil Content-Length (chunked transfer) bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: nil)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "max_upload_bytes = nil bypasses the guard even with oversized Content-Length" do
      with_max_upload_bytes(nil) do
        stub_request(content_type: "multipart/form-data", content_length: 10 * 1024 * 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "application/json content type bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "application/json", content_length: 10 * 1024 * 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "application/x-www-form-urlencoded is subject to the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "application/x-www-form-urlencoded", content_length: 2048)
        expect { controller.send(:__ruact_enforce_upload_limit!) }
          .to raise_error(Ruact::UploadTooLargeError) do |error|
            expect(error.received_bytes).to eq(2048)
            expect(error.limit_bytes).to eq(1024)
          end
      end
    end

    it "Content-Length exactly equal to the limit passes the guard (off-by-one)" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "missing content type (nil) bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: nil, content_length: 10_000)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end
  end
end
