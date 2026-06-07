# frozen_string_literal: true

require "active_support/concern"

# Review patch (2026-06-07) — a direct `require "ruact/server"` (without the
# host having required "ruact" first) must still resolve everything the
# salvaged chains touch at request time: `Ruact.config` (defined in ruact.rb,
# not configuration.rb), `Ruact::UploadTooLargeError`, the ErrorPayload
# pipeline. The gem root never requires this file back (the bare
# `require "ruact"` path stays ActionController-free; the Railtie loads the
# concern), so this is acyclic by construction.
require_relative "../ruact"
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
  #   413/500). On every other request shape — including GET/HEAD requests
  #   regardless of their Accept header — the handler re-raises, so GET
  #   pages, `default_render`, and Phase-1 behavior stay byte-for-byte
  #   untouched. Host `rescue_from` declarations — whether inherited from a
  #   parent class or declared in the host's own body — keep precedence:
  #   the chain only catches what the host did not.
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
      #
      # Review patch (2026-06-07) — handlers the host INHERITED from a parent
      # class must keep precedence too, not just ones declared after the
      # include: Rails walks `rescue_handlers` most-recently-registered
      # first, and a plain `rescue_from` here would land the concern's
      # entries AFTER the inherited ones. The concern's entries are therefore
      # moved to the FRONT of the array, so every host handler — inherited or
      # declared later in the class body — stays more recent and wins.
      inherited_handlers = rescue_handlers
      rescue_from StandardError, with: :__ruact_render_action_error
      rescue_from ActionController::InvalidAuthenticityToken, with: :__ruact_render_action_error
      self.rescue_handlers = (rescue_handlers - inherited_handlers) + inherited_handlers
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

    # D1 (amended by the 2026-06-07 review patch) — render the structured
    # payload only for NON-GET/HEAD function-call requests, with one
    # documented exception: `Ruact::UploadTooLargeError` renders the
    # structured 413 for every request shape. The guard only exists on
    # requests that opted into the concern, and a meaningful 413 beats a
    # re-raised 500 for a native multipart form submit. Everything else
    # re-raises so non-function-call requests keep Rails' default error
    # behavior (AC1 byte-for-byte).
    #
    # The verb gate lives HERE, not in the predicate: function calls are
    # non-GET by the verb rule (epic contract decision #1), so a GET/HEAD
    # carrying `Accept: application/json` (a fetch() against a page action,
    # an API probe) is NOT a function call and must keep stock Rails error
    # behavior — while `__ruact_function_call?` itself stays the raw-Accept
    # discriminator Story 9.2 reuses verbatim.
    def __ruact_render_structured_error?(error)
      return true if error.is_a?(Ruact::UploadTooLargeError)

      __ruact_function_call? && !(request.get? || request.head?)
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
