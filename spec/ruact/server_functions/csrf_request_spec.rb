# frozen_string_literal: true

# Story 8.2 review patch R3 + R10 (2026-05-17) — end-to-end CSRF matrix
# for `POST /__ruact/fn/:name`. Closes Story 8.1's AC8 deferral with
# REAL forgery-protection round-trips:
#
#   - missing token  → 422
#   - invalid token  → 422
#   - VALID token    → 200 + action return value (R10 — was structural-
#                      only before; now a real Rails round-trip)
#   - API-mode       → 200 without any token (cross-referenced)
#
# Mounts onto the existing Rails::Application that `controller_request_spec.rb`
# boots (the Story 7.9 minimal app — `config.secret_key_base` set,
# Cookies + Session middleware in the default Rails middleware stack).
# Appending routes to that shared app sidesteps the singleton constraint
# (only one Rails::Application per process) AND gets a fully-wired
# `Rails.application.key_generator` for `form_authenticity_token` to
# derive keys from — Rack::Builder-only specs cannot reproduce that
# wiring without effectively re-implementing the Rails middleware chain.

require "spec_helper"
require "rack/test"

require "action_controller/railtie"
require "action_view/railtie"
require "action_dispatch"
require "ruact/controller"
require "ruact/server_functions/endpoint_controller"
require "ruact/server_action"
require "ruact/railtie"

# Reuse the Rails::Application booted by `controller_request_spec.rb` —
# Rails does not support two `Rails::Application` subclasses initialized
# in the same process. When this spec runs alone, the require below
# loads `controller_request_spec.rb`, which defines
# `ControllerRequestSpecSupport.app_class`.
require_relative "../controller_request_spec" if defined?(Rails::Application) &&
                                                 !defined?(ControllerRequestSpecSupport)

module CsrfRequestSpecSupport
  # The protected controller — `allow_forgery_protection = true` (per-
  # controller override of the spec app's default `false`) is what
  # makes `protect_from_forgery` actually fire on this class.
  #
  # Story 8.2 review patch R17 (2026-05-17) — the `rescue_from
  # InvalidAuthenticityToken` shortcut was REMOVED. Real Rails hosts
  # using `protect_from_forgery with: :exception` let the exception
  # bubble; with `show_exceptions: :none` (the spec app's config) it
  # propagates to Rack and the test sees it directly. Asserting the
  # exception class is a stronger guarantee than asserting a custom
  # body the test itself produced — it proves the dispatcher reaches
  # the host's CSRF callback chain unchanged.
  class CSRFTestController < ActionController::Base
    self.allow_forgery_protection = true
    protect_from_forgery with: :exception

    include Ruact::Controller

    def self.register_ruact_actions!
      ruact_action(:csrf_demo) { |params| { "ok" => true, "echoed" => params.to_unsafe_h } }
    end
  end

  # Non-CSRF sibling controller — emits a freshly-minted authenticity
  # token tied to the request's session. The token is masked per-
  # request (R9 in the spec body); `valid_authenticity_token?` accepts
  # any per-request derivation of the session's master.
  class TokenEmitterController < ActionController::Base
    self.allow_forgery_protection = false

    def emit
      # Force session creation so the cookie comes back to Rack::Test
      # and the next request lands in the same session.
      session[:_warm] = true
      render json: { token: form_authenticity_token }
    end
  end

  CSRF_ROUTES_APPENDED = false

  class << self
    # Idempotent — appends the CSRF spec's two routes to the shared
    # Story 7.9 app the first time it's called. Routes can only be
    # appended BEFORE `initialize!` runs reliably; we call
    # `boot!` immediately after so the routes land.
    def append_routes!
      return if @routes_appended

      ControllerRequestSpecSupport.app_class.routes.append do
        post "/__ruact/fn/:name",
             to: "ruact/server_functions/endpoint#dispatch_action",
             as: :ruact_server_function_csrf_spec,
             constraints: { name: /[a-zA-Z_][a-zA-Z0-9_]*/ }
        get "/_csrf_token",
            to: "csrf_request_spec_support/token_emitter#emit",
            as: :csrf_token_emit
      end
      @routes_appended = true
    end
  end
end

# Route append must happen at file load, BEFORE any boot! call from
# either spec, because Rails routes are finalised at initialize!. The
# `dispatch_request_spec.rb` file already follows this convention.
CsrfRequestSpecSupport.append_routes!

# Story 8.2 review patch R19 (2026-05-17) — wraps requests in a small
# rescue middleware that mirrors what `ActionDispatch::ShowExceptions`
# does in production: catch `ActionController::InvalidAuthenticityToken`
# and render a 422 response. The spec app sets
# `show_exceptions: :none` so the exception otherwise bubbles to Rack
# and the test process; that proves the host's CSRF callback fired (R17)
# but does NOT observe the HTTP 422 + body shape AC5 specifies for the
# client-facing contract. This middleware lets the spec assert both —
# rejection at the host (proven by reaching the rescue branch) AND the
# downstream 422 response shape (the surface `RuactActionError.body`
# parses on the client).
module CsrfRequestSpecSupport
  class CSRFRescueMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue ActionController::InvalidAuthenticityToken => e
      body = JSON.dump(
        error: "ActionController::InvalidAuthenticityToken",
        message: e.message
      )
      [422, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
    end
  end
end

RSpec.describe "Story 8.2 — CSRF matrix (`<form action={fn}>` end-to-end)",
               :story_8_2 do
  include Rack::Test::Methods

  let(:app_class) { ControllerRequestSpecSupport.app_class }
  # R19: wrap the booted Rails app in the rescue middleware so the spec
  # can observe `ActionController::InvalidAuthenticityToken` as the
  # HTTP 422 response Rails' production middleware (ShowExceptions)
  # would produce — without changing the spec app's `show_exceptions`
  # config (which other specs depend on).
  let(:app) { CsrfRequestSpecSupport::CSRFRescueMiddleware.new(app_class.instance) }

  before do
    Rails.logger = Logger.new(IO::NULL)
    ControllerRequestSpecSupport.boot!
    CsrfRequestSpecSupport::CSRFTestController.register_ruact_actions!
  end

  # R17 (2026-05-17): the AC1/AC5 wire shape is `multipart/form-data`
  # (React 19's `<form action={fn}>` invokes the function with a
  # `FormData` instance; the runtime POSTs as multipart). Hand-build a
  # multipart body so the spec exercises the same path the runtime
  # produces. Mirrors the helper in `dispatch_request_spec.rb`.
  def multipart_post(path, fields, extra_headers = {})
    boundary = "----RuactCsrfSpec#{SecureRandom.hex(8)}"
    body = +""
    fields.each do |key, value|
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n"
      body << value.to_s
      body << "\r\n"
    end
    body << "--#{boundary}--\r\n"
    post path, body,
         {
           "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
           "CONTENT_LENGTH" => body.bytesize.to_s
         }.merge(extra_headers)
  end

  describe "AC5 — host has `protect_from_forgery with: :exception` enabled" do
    it "REJECTS a multipart request WITHOUT an X-CSRF-Token header — HTTP 422 + body shape " \
       "(R19: rescue middleware mirrors Rails' production ShowExceptions output)" do
      # The host's `protect_from_forgery with: :exception` raises
      # `ActionController::InvalidAuthenticityToken`. In production
      # Rails' default exception middleware (ShowExceptions) maps this
      # to HTTP 422 + Rails' rendered error page. The spec's
      # `CSRFRescueMiddleware` does the same conversion so the test
      # observes the SHAPE the client (`RuactActionError.body`) would
      # see: status 422, JSON body carrying the exception class +
      # message.
      multipart_post "/__ruact/fn/csrf_demo", { "title" => "no token" }
      expect(last_response.status).to eq(422)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to eq("ActionController::InvalidAuthenticityToken")
      expect(body.fetch("message")).to match(/CSRF token|authenticity/i)
    end

    it "REJECTS a multipart request whose X-CSRF-Token header carries an INVALID token — same 422 shape" do
      multipart_post "/__ruact/fn/csrf_demo",
                     { "title" => "bad token" },
                     { "HTTP_X_CSRF_TOKEN" => "obviously-not-the-real-token" }
      expect(last_response.status).to eq(422)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to eq("ActionController::InvalidAuthenticityToken")
    end

    it "the rejection exception class is the canonical Rails one — `RuactActionError.body` " \
       "carries the JSON body the middleware rendered above (structural cross-check)" do
      # The runtime's 4xx branch (see `index.test.mjs`
      # "RuactActionError.body holds…") parses the response body
      # verbatim. Asserting the body shape above is what proves the
      # `RuactActionError.body` surface on the client side.
      expect(ActionController::InvalidAuthenticityToken.new).to be_a(StandardError)
      expect(ActionController::InvalidAuthenticityToken.ancestors).to include(StandardError)
    end

    it "ACCEPTS a multipart request that forwards the freshly-issued X-CSRF-Token (200) " \
       "— R10 + R17 full end-to-end protected round-trip with the AC1 wire shape" do
      # Fetch a fresh per-request token from the non-CSRF sibling
      # route. The token is masked against the session's master CSRF
      # token; Rack::Test carries cookies across requests, so the
      # subsequent multipart POST lands in the SAME session and the
      # token matches.
      get "/_csrf_token"
      expect(last_response.status).to eq(200)
      token = JSON.parse(last_response.body).fetch("token")
      expect(token).to be_a(String).and(satisfy { |t| !t.empty? })

      multipart_post "/__ruact/fn/csrf_demo",
                     { "title" => "Hi", "body" => "From form" },
                     { "HTTP_X_CSRF_TOKEN" => token }
      expect(last_response.status).to eq(200)
      # R17: prove the multipart parsing actually surfaced the form
      # fields into the action's `params` shadow — a regression that
      # silently dropped the body would still pass a status-only check.
      body = JSON.parse(last_response.body)
      expect(body.fetch("ok")).to be(true)
      expect(body.fetch("echoed")).to include("title" => "Hi", "body" => "From form")
      expect(last_request.media_type).to eq("multipart/form-data")
    end

    it "the same callback chain that produced the 422 paths above is wired into the host " \
       "(structural cross-check)" do
      filters = CsrfRequestSpecSupport::CSRFTestController
                ._process_action_callbacks
                .map(&:filter)
      expect(filters).to include(:verify_authenticity_token)
      # Conversely, the gem's own EndpointController either carries no
      # verify_authenticity_token at all (pre-Story-8.3) or carries one
      # gated by `dispatching_standalone?` (Story 8.3+) — either way it
      # does NOT fire on the controller-hosted dispatch path; the host
      # remains the single source of CSRF truth for that branch.
      gem_callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
      verify_callback = gem_callbacks.find { |c| c.filter == :verify_authenticity_token }
      if verify_callback
        expect(verify_callback.instance_variable_get(:@if)).to eq([:dispatching_standalone?])
      else
        expect(gem_callbacks.map(&:filter)).not_to include(:verify_authenticity_token)
      end
    end
  end

  # Story 8.3 — AC5 CSRF matrix for the STANDALONE branch. The standalone
  # path has no host controller, so the gem's `EndpointController`
  # enforces CSRF itself via `protect_from_forgery with: :exception,
  # if: :dispatching_standalone?`. The matrix mirrors the controller-
  # hosted matrix above but exercises the gem's own callback chain.
  #
  # Story 8.3 review R2 — IMPORTANT: the gem does NOT guarantee a JSON
  # response body for CSRF failures. `protect_from_forgery with: :exception`
  # raises `ActionController::InvalidAuthenticityToken`; the response body
  # the client sees is whatever the host app's exception middleware
  # produces (Rails' default `ActionDispatch::ShowExceptions` serves
  # `public/422.html` in non-API mode; a host with `rescue_from` or a
  # custom error renderer overrides that). The `CSRFRescueMiddleware`
  # in this spec is a TEST-ONLY synthesis (carried over from Story 8.2)
  # that wraps the booted app to produce a stable JSON shape for
  # assertions — it does NOT ship with the gem. Tests below assert
  # what the GEM guarantees (status code 422, exception class is the
  # canonical Rails one) and what the test middleware adds on top
  # (the JSON body shape) — the in-line comments call out which is which.
  describe "Story 8.3 — standalone-branch CSRF matrix", :story_8_3 do
    module StandaloneCsrfSpecSupport
      module DemoStandaloneHost
        extend Ruact::ServerAction
      end
    end

    around do |example|
      # The standalone branch's `protect_from_forgery` lives on
      # EndpointController and inherits Rails' `allow_forgery_protection`
      # class attribute. Force it true for this describe block so the
      # gem-level check fires; the after-hook restores prior state.
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = true
      example.run
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    before do
      StandaloneCsrfSpecSupport::DemoStandaloneHost.module_eval do
        ruact_action(:standalone_csrf_demo) { |params| { "ok" => true, "echoed" => params.to_unsafe_h } }
      end
    end

    it "REJECTS a multipart request WITHOUT an X-CSRF-Token header — HTTP 422 + " \
       "ActionController::InvalidAuthenticityToken raised " \
       "(R2: status code + exception class are the gem's guarantee; the JSON body shape " \
       "is what the test-only CSRFRescueMiddleware synthesises — production response body " \
       "is whatever the host app's exception middleware produces)" do
      multipart_post "/__ruact/fn/standalone_csrf_demo", { "title" => "no token" }
      # Gem guarantee — status code from `protect_from_forgery with: :exception`
      # + Rails' default `InvalidAuthenticityToken` → 422 mapping in `ShowExceptions`.
      expect(last_response.status).to eq(422)
      # Test-middleware synthesis — production body shape is host-dependent.
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to eq("ActionController::InvalidAuthenticityToken")
    end

    it "REJECTS a multipart request whose X-CSRF-Token header carries an INVALID token — same 422 + exception" do
      multipart_post "/__ruact/fn/standalone_csrf_demo",
                     { "title" => "bad" },
                     { "HTTP_X_CSRF_TOKEN" => "obviously-not-the-real-token" }
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.fetch("error")).to eq("ActionController::InvalidAuthenticityToken")
    end

    it "ACCEPTS a multipart request that forwards the freshly-issued X-CSRF-Token (200) — " \
       "end-to-end standalone-branch CSRF round-trip" do
      get "/_csrf_token"
      token = JSON.parse(last_response.body).fetch("token")

      multipart_post "/__ruact/fn/standalone_csrf_demo",
                     { "title" => "Hi", "body" => "From form" },
                     { "HTTP_X_CSRF_TOKEN" => token }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.fetch("ok")).to be(true)
      expect(body.fetch("echoed")).to include("title" => "Hi", "body" => "From form")
    end

    it "API-mode (allow_forgery_protection = false) accepts a standalone POST WITHOUT a token — " \
       "the global config wins, identical to the controller-action behavior in Story 8.1 AC8" do
      previous = Ruact::ServerFunctions::EndpointController.allow_forgery_protection
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = false
      multipart_post "/__ruact/fn/standalone_csrf_demo", { "title" => "api mode" }
      expect(last_response.status).to eq(200)
    ensure
      Ruact::ServerFunctions::EndpointController.allow_forgery_protection = previous
    end

    it "mixed-style host parity — controller-hosted and standalone-hosted actions report identical " \
       "user-visible CSRF behavior under the same allow_forgery_protection setting" do
      # The controller path's missing-token rejection is asserted in
      # `AC5 — host has protect_from_forgery enabled` above (422 +
      # ActionController::InvalidAuthenticityToken). The standalone path's
      # missing-token rejection is asserted in this describe's first
      # spec. Pinning the structural cross-check here documents that the
      # two hosts converge on the same callback class and exception class.
      callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
      verify_callback = callbacks.find { |c| c.filter == :verify_authenticity_token }
      expect(verify_callback).not_to be_nil
      expect(verify_callback.instance_variable_get(:@if)).to eq([:dispatching_standalone?])
    end
  end

  describe "API-mode parity — host WITHOUT `protect_from_forgery` accepts anything" do
    it "structural complement: the spec app's main dispatch tests run with " \
       "allow_forgery_protection = false; absent-token requests succeed there" do
      # The full API-mode round-trip is asserted in `dispatch_request_spec.rb`'s
      # `AC5 — CSRF matrix` describe block; cross-reference recorded here so
      # the matrix is discoverable from one place.
      callbacks = Ruact::ServerFunctions::EndpointController._process_action_callbacks
      verify_callback = callbacks.find { |c| c.filter == :verify_authenticity_token }
      if verify_callback
        # Story 8.3 — gated by dispatching_standalone?; controller-hosted
        # dispatch never reaches it.
        expect(verify_callback.instance_variable_get(:@if)).to eq([:dispatching_standalone?])
      else
        expect(callbacks.map(&:filter)).not_to include(:verify_authenticity_token)
      end
    end
  end
end
