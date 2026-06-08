# frozen_string_literal: true

# Story 9.1 — request-cycle + unit spec for the Story 8.5 upload guard
# RE-ANCHORED on the `Ruact::Server` concern (its final, v2 home). Replaces
# `server_functions/endpoint_controller_upload_spec.rb` (removed in the same
# commit — AC5). Pins, against REAL host-controller routes:
#
#   - oversized multipart → 413 + structured `upload_limit` payload through
#     the concern's salvaged chain (inventory A7, A14, B7, B9, B11)
#   - guard fires BEFORE CSRF verification — 413, not 403 (B6 / Pitfall #4)
#   - the three carve-outs: nil limit (B2), content-type allowlist (B3),
#     absent Content-Length (B4); off-by-one equal-passes (B5)
#   - D1: the 413 renders structured for native form submits too (no
#     function-call Accept header) — the documented UploadTooLargeError
#     exception to the re-raise rule
#   - D2: GET/HEAD requests skip the guard entirely (C5)
#   - small uploads reach the action as ActionDispatch::Http::UploadedFile
#     with metadata + mixed non-file fields intact (transplant sanity)
#
# Mounts on the shared Story-7.9 Rails app; deliberately independent of the
# v1 `server_functions/dispatch_request_spec.rb` (demolished in Story 9.9).

require "action_controller/railtie"
require "action_view/railtie"

require "spec_helper"
require "rack/test"
require "tempfile"

require "ruact/server"

require_relative "controller_request_spec" unless defined?(ControllerRequestSpecSupport)

SERVER_UPLOAD_SPEC_PNG_PATH =
  File.expand_path("../support/fixtures/pixel.png", __dir__).freeze
SERVER_UPLOAD_SPEC_PNG_BYTES = File.binread(SERVER_UPLOAD_SPEC_PNG_PATH).freeze

module ServerUploadSpecSupport
  class UploadsServerController < ActionController::Base
    include Ruact::Server

    def create_upload
      uploaded = params[:cover]
      render json: {
        "title" => params[:title].to_s,
        "uploaded_class" => uploaded.class.name,
        "original_filename" => uploaded.respond_to?(:original_filename) ? uploaded.original_filename : nil,
        "byte_size" => uploaded.respond_to?(:read) ? uploaded.read.bytesize : nil
      }
    end
  end

  # CSRF-enforcing host for the Pitfall #4 ordering proof (B6) — forgery is
  # flipped on per-example via the class-level `allow_forgery_protection`.
  class ForgeryUploadsServerController < ActionController::Base
    include Ruact::Server

    protect_from_forgery with: :exception

    def create_protected_upload
      render json: { "ok" => true }
    end
  end

  # Review patch (2026-06-08) — pathological host that re-orders CSRF ahead of
  # the prepended upload guard via `protect_from_forgery prepend: true`. The
  # concern must detect the inversion and fail loudly rather than silently
  # 403 an oversized tokenless request before the intended 413 (AC4).
  class InvertedGuardUploadsController < ActionController::Base
    include Ruact::Server

    protect_from_forgery with: :exception, prepend: true

    # A GET page action: CSRF verification is a no-op for GET, so the prepended
    # guard still runs and surfaces the ordering inversion immediately — the
    # realistic "fail on the first page load" path (an oversized tokenless POST
    # would already be 403'd by the misordered CSRF check before the guard, the
    # very breakage this detection exists to prevent in development).
    def page
      render plain: "should never render on an inverted host"
    end

    # Review patch (2026-06-08, round 3) — the exact broken shape the reviewer
    # named: an oversized multipart POST without a CSRF token. On an inverted
    # host Rails runs verify_authenticity_token BEFORE the prepended guard, so
    # the guard never gets to 413. The concern must still fail loudly here
    # (via the rescue chain re-asserting the precedence invariant) rather than
    # quietly 403-ing — the misconfiguration cannot serve a single request.
    def create
      render json: { "ok" => true }
    end
  end
end

if defined?(ControllerRequestSpecSupport) &&
   !ControllerRequestSpecSupport.instance_variable_get(:@__ruact_server_upload_routes_appended)
  ControllerRequestSpecSupport.instance_variable_set(:@__ruact_server_upload_routes_appended, true)
  ControllerRequestSpecSupport.app_class.routes.append do
    post "/server_upload",           to: "server_upload_spec_support/uploads_server#create_upload"
    post "/server_upload/protected", to: "server_upload_spec_support/forgery_uploads_server#create_protected_upload"
    get  "/server_upload/inverted",  to: "server_upload_spec_support/inverted_guard_uploads#page"
    post "/server_upload/inverted",  to: "server_upload_spec_support/inverted_guard_uploads#create"
  end
end

RSpec.describe "Story 9.1: Ruact::Server concern — salvaged upload guard", :story_9_1 do
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  let(:app)       { app_class.instance }

  let(:function_call_accept) { { "HTTP_ACCEPT" => "application/json" } }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
  end

  def with_oversized_tempfile
    large = Tempfile.new(["big", ".bin"])
    large.binmode
    large.write("x" * 4096) # 4 KB > the 1 KB caps below
    large.rewind
    yield large
  ensure
    large.close
    large.unlink
  end

  def cap_max_upload_bytes(value)
    # spec_helper's global before-hook resets @config; re-prime AFTER it so
    # the tight cap sticks for the example body (same dance as the v1 spec).
    Ruact.instance_variable_set(:@config, nil)
    Ruact.instance_variable_set(:@configured_at_least_once, false)
    Ruact.configure { |c| c.max_upload_bytes = value }
  end

  describe "transplant sanity — small multipart upload reaches the action" do
    it "params[:cover] arrives as ActionDispatch::Http::UploadedFile with metadata; mixed fields intact" do
      post "/server_upload",
           {
             "title" => "My Post",
             "cover" => Rack::Test::UploadedFile.new(SERVER_UPLOAD_SPEC_PNG_PATH, "image/png")
           },
           function_call_accept
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
      expect(body.fetch("original_filename")).to eq("pixel.png")
      expect(body.fetch("byte_size")).to eq(SERVER_UPLOAD_SPEC_PNG_BYTES.bytesize)
      expect(body.fetch("title")).to eq("My Post")
    end
  end

  describe "oversized multipart → 413 + structured upload_limit payload (A7/A14/B7/B9/B11)" do
    before { cap_max_upload_bytes(1024) }

    it "function-call request: 413 with discriminator, real action_name, and the dev-only upload_limit block" do
      with_oversized_tempfile do |large|
        post "/server_upload",
             {
               "title" => "Too big",
               "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
             },
             function_call_accept
        expect(last_response.status).to eq(413)
        body = JSON.parse(last_response.body)
        expect(body).to include(
          "_ruact_server_action_error" => true,
          "error_class" => "Ruact::UploadTooLargeError",
          # A14 — the controller's REAL action name, no registry-symbol
          # fallback dance (the v1 path_parameters[:name] fallback is gone).
          "action_name" => "create_upload"
        )
        expect(body.fetch("upload_limit")).to include("limit_bytes" => 1024)
        # B7 — received_bytes is the WIRE Content-Length: file bytes PLUS
        # multipart boundary + field overhead.
        expect(body.fetch("upload_limit").fetch("received_bytes")).to be > 4096
      end
    end

    it "D1 — a native form submit (no function-call Accept) ALSO gets the structured 413" do
      # UploadTooLargeError is the documented exception to the re-raise rule:
      # the guard only exists on requests that opted into the concern, and a
      # meaningful 413 beats a re-raised 500 for every caller shape.
      with_oversized_tempfile do |large|
        post "/server_upload",
             {
               "title" => "Too big, browser shape",
               "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
             }
        expect(last_response.status).to eq(413)
        body = JSON.parse(last_response.body)
        expect(body.fetch("_ruact_server_action_error")).to be(true)
        expect(body.fetch("error_class")).to eq("Ruact::UploadTooLargeError")
      end
    end
  end

  describe "guard fires BEFORE CSRF verification (B6 / Pitfall #4)" do
    around do |example|
      previous = ServerUploadSpecSupport::ForgeryUploadsServerController.allow_forgery_protection
      ServerUploadSpecSupport::ForgeryUploadsServerController.allow_forgery_protection = true
      example.run
    ensure
      ServerUploadSpecSupport::ForgeryUploadsServerController.allow_forgery_protection = previous
    end

    before { cap_max_upload_bytes(1024) }

    it "oversized request WITHOUT a CSRF token returns 413, not 403" do
      with_oversized_tempfile do |large|
        post "/server_upload/protected",
             {
               "title" => "Too big, no token",
               "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
             },
             function_call_accept
        expect(last_response.status).to eq(413)
        expect(JSON.parse(last_response.body).fetch("error_class")).to eq("Ruact::UploadTooLargeError")
      end
    end
  end

  describe "upload guard must precede CSRF — inverted host fails loudly (AC4 / Pitfall #4, review patch)" do
    it "raises Ruact::ConfigurationError on the first GET page load instead of silently mis-ordering" do
      # CSRF verification is a no-op for GET, so the prepended guard still runs
      # and detects that :verify_authenticity_token was prepended ahead of it.
      # The ConfigurationError re-raises (GET → stock Rails handling) and, under
      # show_exceptions = :none, propagates to the caller — the loud failure
      # that makes the misordering impossible to ship unnoticed.
      expect do
        get "/server_upload/inverted"
      end.to raise_error(Ruact::ConfigurationError, /upload guard/)
    end
  end

  describe "inverted host — oversized tokenless POST also fails loudly (AC4 / Pitfall #4, review patch round 3)" do
    around do |example|
      previous = ServerUploadSpecSupport::InvertedGuardUploadsController.allow_forgery_protection
      ServerUploadSpecSupport::InvertedGuardUploadsController.allow_forgery_protection = true
      example.run
    ensure
      ServerUploadSpecSupport::InvertedGuardUploadsController.allow_forgery_protection = previous
    end

    before { cap_max_upload_bytes(1024) }

    it "raises Ruact::ConfigurationError instead of silently 403-ing before the 413" do
      # CSRF (prepended ahead) raises InvalidAuthenticityToken before the guard
      # ever runs, so the inversion cannot surface from the guard itself. The
      # rescue chain re-asserts the precedence invariant and propagates the
      # ConfigurationError — the misconfigured controller serves NO request.
      with_oversized_tempfile do |large|
        expect do
          post "/server_upload/inverted",
               {
                 "title" => "oversized, no token",
                 "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
               }
        end.to raise_error(Ruact::ConfigurationError, /upload guard/)
      end
    end
  end

  describe "carve-out — max_upload_bytes = nil disables the gem-side guard (B2)" do
    before { cap_max_upload_bytes(nil) }

    it "a body of any size flows through to the action" do
      with_oversized_tempfile do |large|
        post "/server_upload",
             {
               "title" => "no cap",
               "cover" => Rack::Test::UploadedFile.new(large.path, "application/octet-stream")
             },
             function_call_accept
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).fetch("uploaded_class")).to eq("ActionDispatch::Http::UploadedFile")
      end
    end
  end

  describe "carve-out — application/json bypasses the guard (B3, request-cycle)" do
    before { cap_max_upload_bytes(1024) }

    it "a 4 KB JSON body passes the guard and reaches the action" do
      payload = { "title" => "big json", "blob" => "x" * 4096 }
      post "/server_upload", payload.to_json,
           { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
      expect(last_response.status).to eq(200)
      # No file in a JSON body — the action reports the params leaf class.
      expect(JSON.parse(last_response.body).fetch("uploaded_class")).to eq("NilClass")
    end
  end

  # Unit-level coverage of the short-circuit branches — directly against a
  # host controller instance, mirroring the v1 unit block but with the
  # concern's D2 verb gate in play (request.get? / request.head?).
  describe "Unit — __ruact_enforce_upload_limit! short-circuits (B2–B5, C5/D2)" do
    let(:controller) { ServerUploadSpecSupport::UploadsServerController.new }

    def with_max_upload_bytes(value)
      cap_max_upload_bytes(value)
      yield
    ensure
      Ruact.instance_variable_set(:@config, nil)
      Ruact.instance_variable_set(:@configured_at_least_once, false)
    end

    def stub_request(content_type:, content_length:, http_method: "POST")
      request = instance_double(
        ActionDispatch::Request,
        content_length: content_length,
        get?: http_method == "GET",
        head?: http_method == "HEAD"
      )
      allow(request).to receive(:content_mime_type)
        .and_return(content_type ? Mime::Type.lookup(content_type) : nil)
      allow(controller).to receive(:request).and_return(request)
    end

    it "B4 — nil Content-Length (chunked transfer) bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: nil)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "B2 — max_upload_bytes = nil bypasses the guard even with oversized Content-Length" do
      with_max_upload_bytes(nil) do
        stub_request(content_type: "multipart/form-data", content_length: 10 * 1024 * 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "B3 — application/json content type bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "application/json", content_length: 10 * 1024 * 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "B3 — missing content type (nil) bypasses the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: nil, content_length: 10_000)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "B3/B8 — application/x-www-form-urlencoded is subject to the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "application/x-www-form-urlencoded", content_length: 2048)
        expect { controller.send(:__ruact_enforce_upload_limit!) }
          .to raise_error(Ruact::UploadTooLargeError) do |error|
            expect(error.received_bytes).to eq(2048)
            expect(error.limit_bytes).to eq(1024)
          end
      end
    end

    it "B5 — Content-Length exactly equal to the limit passes the guard (off-by-one)" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: 1024)
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "C5/D2 — a GET request skips the guard even with an oversized multipart body" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: 10 * 1024 * 1024, http_method: "GET")
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end

    it "C5/D2 — a HEAD request skips the guard" do
      with_max_upload_bytes(1024) do
        stub_request(content_type: "multipart/form-data", content_length: 10 * 1024 * 1024, http_method: "HEAD")
        expect { controller.send(:__ruact_enforce_upload_limit!) }.not_to raise_error
      end
    end
  end
end
