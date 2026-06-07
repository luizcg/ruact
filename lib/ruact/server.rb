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

    # Raw discriminator (review patch, 2026-06-08) — does the request's
    # `Accept` header contain `application/json`? This is exactly what the 8.1
    # runtime sends on every `_makeRef` fetch (Bucket 2 — imperative
    # `await createPost(...)`). Browser navigation and `<form>` submits never
    # include `application/json` in their Accept header, and Flight requests
    # send `text/x-component`.
    #
    # Deliberately NOT `request.format`: the Rails format negotiation is
    # influenced by path extensions (`/posts.json`) and `params[:format]`,
    # neither of which may flip the bucket. This is the verb-AGNOSTIC header
    # check; the semantic predicate {#__ruact_function_call?} layers the verb
    # rule on top.
    def __ruact_json_accept?
      request.headers["Accept"]&.include?("application/json") || false
    end

    # Story 9.1 AC2 — THE discrimination point: "is this request a function
    # call?". A function call is a JSON-Accept request that is ALSO non-GET/
    # HEAD: function calls are non-GET by the verb rule (epic contract
    # decision #1), so a GET/HEAD carrying `Accept: application/json` (a
    # `fetch()` against a page action, an API probe) is NOT one.
    #
    # Review patch (2026-06-08) — the verb gate that used to live only in
    # {#__ruact_render_structured_error?} now lives HERE, in the predicate
    # itself, so Story 9.2 reuses the CORRECT contract verbatim as the
    # dual-bucket discriminator (the raw header check is {#__ruact_json_accept?}).
    # The predicate lives in one place only.
    def __ruact_function_call?
      __ruact_json_accept? && !(request.get? || request.head?)
    end

    # D1 (amended by the 2026-06-07 / 2026-06-08 review patches) — render the
    # structured payload only for NON-GET/HEAD requests; within those, for a
    # function call ({#__ruact_function_call?}) or any
    # `Ruact::UploadTooLargeError`. Everything else re-raises so
    # non-function-call requests keep Rails' default error behavior (AC1
    # byte-for-byte).
    #
    # The verb gate is the FIRST thing checked so it covers the
    # `UploadTooLargeError` branch too (2026-06-08 patch): the guard never
    # produces that error on a GET/HEAD (it skips those — D2), so the only way
    # one reaches this handler on a GET is a manual `raise` inside a page
    # action — which must keep stock Rails behavior, not be swallowed into a
    # structured 413. For the non-GET case the documented exception still
    # holds: a `UploadTooLargeError` from a native multipart form submit
    # (Bucket 1, no JSON Accept) renders a meaningful 413 rather than a
    # re-raised 500.
    def __ruact_render_structured_error?(error)
      return false if request.get? || request.head?

      error.is_a?(Ruact::UploadTooLargeError) || __ruact_function_call?
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

    # Review patch (2026-06-08) — AC4 / Pitfall #4 made executable. The upload
    # guard is installed via `prepend_before_action`, so it normally wins the
    # callback race against `verify_authenticity_token`. But a host can
    # re-order CSRF ahead of it with `protect_from_forgery prepend: true`
    # (which PREPENDS `verify_authenticity_token`), in which case an oversized
    # multipart request WITHOUT a CSRF token is rejected with 403 before the
    # intended 413 — silently violating AC4. Rather than document this as the
    # host's responsibility, the concern detects the inversion in the compiled
    # callback chain and fails loudly.
    #
    # The check runs for every verb (it is invoked before the
    # {#__ruact_upload_guard_applicable?} short-circuit), so it surfaces on the
    # first request of any kind — GET/HEAD reach the guard because CSRF
    # verification is a no-op for them, making page loads fail immediately in
    # development when the order is wrong.
    def __ruact_verify_upload_guard_precedence!
      return unless __ruact_csrf_precedes_upload_guard?

      raise Ruact::ConfigurationError,
            "#{self.class} orders :verify_authenticity_token before Ruact::Server's " \
            "upload guard (:__ruact_enforce_upload_limit!), most likely via " \
            "`protect_from_forgery prepend: true`. The upload guard must run first so " \
            "an oversized multipart request rejects with 413 before CSRF verification " \
            "can return 403 (AC4 / Pitfall #4). Remove `prepend: true` from " \
            "protect_from_forgery, or move `include Ruact::Server` after the " \
            "protect_from_forgery call."
    end

    # Pure inspection of the compiled before-callback chain — no request state,
    # so it is unit-testable in isolation (the review patch's "prepend: true
    # edge case is detected" spec calls it directly). Returns true only when
    # BOTH callbacks are present AND `verify_authenticity_token` is ordered
    # ahead of the upload guard.
    def __ruact_csrf_precedes_upload_guard?
      before_filters = self.class._process_action_callbacks
                           .select { |callback| callback.kind == :before }
                           .map(&:filter)
      guard_index = before_filters.index(:__ruact_enforce_upload_limit!)
      csrf_index = before_filters.index(:verify_authenticity_token)
      return false if guard_index.nil? || csrf_index.nil?

      csrf_index < guard_index
    end
  end
end
