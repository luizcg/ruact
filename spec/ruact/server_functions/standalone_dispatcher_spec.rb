# frozen_string_literal: true

# Story 8.3 — `Ruact::ServerFunctions::StandaloneDispatcher`: AC2 + AC3
# dispatch shape: JSON / multipart / URL-encoded bodies; nil → 204; Hash →
# 200 JSON; Array → 200 JSON; `Ruact::ActionError` → status + body; unknown
# content-type → empty params; params shadow is `ActionController::Parameters`.

require "spec_helper"
require "action_controller"
require "action_dispatch"
require "rack"
require "securerandom"

module Ruact
  module ServerFunctions
    RSpec.describe StandaloneDispatcher, :story_8_3 do
      let(:posts_module) do
        Module.new do
          extend Ruact::ServerAction

          def self.name
            "StandaloneDispatcherHost"
          end
        end
      end

      def make_request(body:, content_type:)
        env = Rack::MockRequest.env_for(
          "/__ruact/fn/whatever",
          method: "POST",
          input: body,
          "CONTENT_TYPE" => content_type
        )
        ActionDispatch::Request.new(env)
      end

      def make_response
        ActionDispatch::Response.new.tap do |resp|
          # Touch the response so its internal state is initialized.
          resp.request = nil
        end
      end

      def register_and_entry(symbol, &block)
        posts_module.module_eval { ruact_action(symbol, &block) }
        Ruact.action_registry.entries[symbol]
      end

      describe "AC2 — content-type routing into params shadow" do
        it "parses application/json bodies" do
          entry = register_and_entry(:json_echo, &:to_unsafe_h)
          request = make_request(body: '{"title":"Hi"}', content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(response.headers["Content-Type"]).to include("application/json")
          expect(JSON.parse(response.body)).to eq("title" => "Hi")
        end

        it "parses multipart/form-data bodies (Story 8.3 review R5 — AC9 multipart coverage)" do
          # Hand-build a multipart body so the dispatcher exercises the same
          # `request.request_parameters` path the runtime's `<form action>`
          # wire shape produces. Mirrors the `multipart_post` helper in
          # dispatch_request_spec.rb.
          boundary = "----RuactDispatcherSpec#{SecureRandom.hex(8)}"
          body = +""
          body << "--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
          body << "From multipart\r\n"
          body << "--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"body\"\r\n\r\n"
          body << "Multipart body\r\n"
          body << "--#{boundary}--\r\n"

          entry = register_and_entry(:multipart_echo, &:to_unsafe_h)
          request = make_request(body: body, content_type: "multipart/form-data; boundary=#{boundary}")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq(
            "title" => "From multipart",
            "body" => "Multipart body"
          )
        end

        it "parses application/x-www-form-urlencoded bodies" do
          entry = register_and_entry(:form_echo, &:to_unsafe_h)
          request = make_request(
            body: "title=Hello&body=World",
            content_type: "application/x-www-form-urlencoded"
          )
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("title" => "Hello", "body" => "World")
        end

        it "returns an empty params hash for unknown content types" do
          entry = register_and_entry(:unknown_ct) { |params| { "keys" => params.to_unsafe_h.keys } }
          request = make_request(body: "ignored", content_type: "application/xml")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("keys" => [])
        end

        it "treats an empty JSON body as an empty hash" do
          entry = register_and_entry(:empty_json, &:to_unsafe_h)
          request = make_request(body: "", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq({})
        end

        it "wraps a scalar JSON top-level value under the `_value` key (mirrors controller path)" do
          entry = register_and_entry(:scalar_json) { |params| { value: params[:_value] } }
          request = make_request(body: "42", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("value" => 42)
        end

        it "exposes the params shadow as ActionController::Parameters (strong params API)" do
          entry = register_and_entry(:strong) do |params|
            permitted = params.require(:post).permit(:title)
            { "permitted" => permitted.to_h }
          end
          request = make_request(
            body: '{"post":{"title":"Hi","evil":"ignored"}}',
            content_type: "application/json"
          )
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("permitted" => { "title" => "Hi" })
        end
      end

      describe "AC2 — response shape" do
        it "renders 204 No Content when the block returns nil" do
          entry = register_and_entry(:nil_return) { |_params| nil }
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(204)
          expect(response.body.to_s).to eq("")
        end

        it "renders 200 + JSON when the block returns a Hash" do
          entry = register_and_entry(:hash_return) { |_params| { ok: true } }
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("ok" => true)
        end

        it "renders 200 + JSON when the block returns an Array" do
          entry = register_and_entry(:array_return) { |_params| [1, 2, 3] }
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq([1, 2, 3])
        end

        it "renders 200 + JSON when the block returns a scalar" do
          entry = register_and_entry(:string_return) { |_params| "pong" }
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(200)
          expect(JSON.parse(response.body)).to eq("pong")
        end
      end

      describe "Story 8.3 review R3 — malformed JSON → structured 400" do
        it "renders 400 + JSON {error} when the JSON body is malformed " \
           "(parity with the controller-DSL path's malformed-JSON handler)" do
          entry = register_and_entry(:malformed_demo) { |_p| { ok: true } }
          request = make_request(body: "{ not json", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(400)
          body = JSON.parse(response.body)
          expect(body.fetch("error")).to match(/ruact action :malformed_demo received malformed JSON body/)
        end

        it "does NOT invoke the block when the body cannot be parsed" do
          block_called = false
          entry = register_and_entry(:never_runs) do |_p|
            block_called = true
            { ok: true }
          end
          request = make_request(body: "{ broken", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(block_called).to be(false)
          expect(response.status).to eq(400)
        end
      end

      describe "AC2 — Ruact::ActionError → status + body" do
        it "renders the error's integer status + JSON body verbatim" do
          entry = register_and_entry(:raise_action_error) do |_params|
            raise Ruact::ActionError.new(status: 422, body: { error: "invalid" })
          end
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(422)
          expect(JSON.parse(response.body)).to eq("error" => "invalid")
        end

        it "translates a Symbol status to the matching HTTP code" do
          entry = register_and_entry(:raise_symbol_status) do |_params|
            raise Ruact::ActionError.new(status: :unauthorized, body: { error: "no" })
          end
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(401)
          expect(JSON.parse(response.body)).to eq("error" => "no")
        end

        it "renders nil body as empty when ActionError.body is nil" do
          entry = register_and_entry(:raise_no_body) do |_params|
            raise Ruact::ActionError.new(status: 418, body: nil)
          end
          request = make_request(body: "{}", content_type: "application/json")
          response = make_response

          described_class.dispatch(entry, request, response)

          expect(response.status).to eq(418)
          expect(response.body.to_s).to eq("")
        end
      end
    end
  end
end
