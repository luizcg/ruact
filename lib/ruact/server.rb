# frozen_string_literal: true

require "active_support/concern"

require_relative "server_functions/error_rendering"

module Ruact
  # Story 9.1 (route-driven redesign, Phase A) — the v2 server-functions
  # marker concern.
  #
  #   class PostsController < ApplicationController
  #     include Ruact::Server        # the ONLY marker — no per-action DSL
  #
  #     def create                   # non-GET routed action → callable server function
  #       @post = Post.create!(title: params[:title])
  #       redirect_to @post
  #     end
  #   end
  #
  # Per the 2026-06-02 ADR addendum (Story 9-0,
  # `docs/internal/decisions/server-functions-api.md`), exposure is decided by
  # `routes.rb` — the Story 9.3 codegen reads `Rails.application.routes`
  # filtered to non-GET routes on controllers that include this concern. The
  # concern itself registers NOTHING and emits NOTHING; at this story it is a
  # pure marker plus the new home of the two salvaged Epic-8 subsystems,
  # running on the host controller's own callback chain:
  #
  # - **Story 8.4 structured-error chain** — `rescue_from StandardError` (+ an
  #   explicit `ActionController::InvalidAuthenticityToken` registration that
  #   preempts Rails' default `handle_unverified_request`, Pitfall #1). On
  #   function-call requests ({#__ruact_function_call?}) an uncaught exception
  #   renders the structured JSON payload (discriminator
  #   `_ruact_server_action_error: true`, four baseline fields, dev/prod split
  #   via `Ruact.config.dev_error_payload_enabled`, status mapping 422/403/
  #   413/500). On every other request shape the handler re-raises, so GET
  #   pages, `default_render`, and Phase-1 behavior stay byte-for-byte
  #   untouched. Host `rescue_from` declarations land later in the class body
  #   and therefore keep precedence — the chain only catches what the host
  #   did not.
  # - **Story 8.5 upload guard** — `prepend_before_action` enforcing
  #   `Ruact.config.max_upload_bytes` against the wire `Content-Length`
  #   BEFORE Rack's multipart parser and BEFORE CSRF verification (an
  #   oversized request 413s without leaking CSRF state, Pitfall #4). The
  #   three carve-outs are preserved: nil limit, non-multipart/urlencoded
  #   content type, absent Content-Length. New here (D2): GET/HEAD requests
  #   skip the guard entirely. The 413 renders structured for ALL request
  #   shapes (D1) — a meaningful 413 beats a re-raised 500 for native form
  #   submits too.
  #
  # Both bodies live in {Ruact::ServerFunctions::ErrorRendering}, shared with
  # the v1 {Ruact::ServerFunctions::EndpointController} during the
  # strangler-fig transition so the wire contract is identical by
  # construction. Dual-bucket response negotiation (ivar serialization,
  # `$redirect`, 204, `Vary: Accept`) is Story 9.2; this concern only
  # contributes the discrimination predicate 9.2 will reuse.
  module Server
    extend ActiveSupport::Concern

    include Ruact::ServerFunctions::ErrorRendering

    included do
      # Story 8.5 salvage — prepended so the size check wins the race against
      # every other callback, including `verify_authenticity_token`.
      prepend_before_action :__ruact_enforce_upload_limit!

      # Story 8.4 salvage — same registration order as v1 (Pitfall #1): the
      # generic StandardError entry first, the explicit
      # InvalidAuthenticityToken entry second so it wins Rails'
      # most-recently-registered handler walk for CSRF failures.
      rescue_from StandardError, with: :__ruact_render_action_error
      rescue_from ActionController::InvalidAuthenticityToken, with: :__ruact_render_action_error
    end

    private

    # Story 9.1 AC2 — THE discrimination point: "is this request a function
    # call?". Keyed on the raw `Accept` header containing `application/json`,
    # which is exactly what the 8.1 runtime sends on every `_makeRef` fetch
    # (Bucket 2 — imperative `await createPost(...)`). Browser navigation and
    # `<form>` submits never include `application/json` in their Accept
    # header, and Flight requests send `text/x-component` — both fall through
    # to Bucket 1 / Phase-1 behavior.
    #
    # Deliberately NOT `request.format`: the Rails format negotiation is
    # influenced by path extensions (`/posts.json`) and `params[:format]`,
    # neither of which may flip the bucket. Story 9.2 reuses this helper
    # verbatim as the dual-bucket discriminator — it lives in one place only.
    def __ruact_function_call?
      request.headers["Accept"]&.include?("application/json") || false
    end

    # D1 — render the structured payload only for function-call requests,
    # with one documented exception: `Ruact::UploadTooLargeError` renders the
    # structured 413 for every request shape. The guard only exists on
    # requests that opted into the concern, and a meaningful 413 beats a
    # re-raised 500 for a native multipart form submit. Everything else
    # re-raises so non-function-call requests keep Rails' default error
    # behavior (AC1 byte-for-byte).
    def __ruact_render_structured_error?(error)
      __ruact_function_call? || error.is_a?(Ruact::UploadTooLargeError)
    end

    # D2 — the v1 endpoint was POST-only so the guard never saw GETs; on a
    # host controller it must skip GET/HEAD so page actions stay
    # byte-for-byte untouched (AC1) while every non-GET action — both
    # buckets — is protected (AC4 says "non-GET action", not "function
    # call": native multipart form submits are exactly where uploads come
    # from).
    def __ruact_upload_guard_applicable?
      !(request.get? || request.head?)
    end
  end
end
