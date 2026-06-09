# frozen_string_literal: true

require "active_support/concern"

# Review patch (2026-06-07) — a direct `require "ruact/server"` (without the
# host having required "ruact" first) must still resolve everything the
# salvaged chains touch at request time: `Ruact.config` (defined in ruact.rb,
# not configuration.rb), `Ruact::UploadTooLargeError`, the ErrorPayload
# pipeline. The gem root never requires this file back (the bare
# `require "ruact"` path stays ActionController-free; the Railtie loads the
# concern), so this is acyclic by construction.
require "uri"
require_relative "../ruact"
require_relative "server_functions/error_rendering"
require_relative "server_functions/bucket_two_payload"

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
  #   BEFORE Rack's multipart parser. The three carve-outs are preserved:
  #   nil limit, non-multipart/urlencoded content type, absent
  #   Content-Length. New here (D2): GET/HEAD requests skip the guard
  #   entirely. The 413 renders structured for ALL request shapes (D1) —
  #   a meaningful 413 beats a re-raised 500 for native form submits too.
  #   Contract simplification: the concern assumes the host includes it after
  #   `protect_from_forgery`; no runtime callback-order verifier runs here.
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
      # Story 9.2 AC6 — `Vary: Accept` on every non-GET response shape. The same
      # URL + verb serves two bodies discriminated solely on `Accept`, so a
      # cache MUST vary on it (never serve Flight to a JSON caller or vice-versa).
      # Prepended FIRST here so the upload guard (prepended next) still lands
      # ahead of it — keeping the Story 8.5 "guard wins the callback race"
      # invariant. Vary therefore runs on every shape EXCEPT the 413 upload
      # rejection (the guard aborts first); the 200 / 204 / `$redirect` / Flight
      # / structured-500 / 403-CSRF shapes all carry it.
      prepend_before_action :__ruact_set_vary_on_accept!

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

    # Story 9.2 AC2/AC4 (D1) — Bucket-2 success-path negotiation. When the
    # action finished without an explicit render on a function-call request
    # ({#__ruact_function_call?} — `Accept: application/json`, non-GET), serialize
    # the action's exposed instance variables (Rails `view_assigns`, verbatim —
    # the same set a view would see) as a JSON object keyed by ivar name, or
    # `204 No Content` when none were set. Any other request shape falls through
    # to `super` so Bucket-1 rendering — the host's `Ruact::Controller` Flight
    # re-render, then Rails — is byte-for-byte unchanged (AC1).
    #
    # The exposed-ivar set is Rails' own `view_assigns` with no custom filtering:
    # Rails already excludes its protected `@_`-prefixed internals (including the
    # CSRF `@_marked_for_same_origin_verification` flag), so what remains is
    # exactly what the action assigned. Each value is serialized through the
    # `ruact_props` / `Ruact::Serializable` / `strict_serialization` rules
    # ({Ruact::ServerFunctions::BucketTwoPayload}); a single ivar stays keyed
    # (no magic unwrap).
    def default_render(*)
      return super unless __ruact_function_call?

      assigns = view_assigns
      return head(:no_content) if assigns.empty?

      render json: ServerFunctions::BucketTwoPayload.build(
        assigns, strict: Ruact.config.strict_serialization
      )
    end

    # Story 9.2 AC3 (D2) — on a function-call request, `redirect_to` surfaces as
    # a JSON redirect directive — body `"$redirect" => "<path>"` (the runtime
    # follows it client-side; re-targeting/following is Story 9.3) instead of a
    # 302 or a Flight redirect row. Any other request shape falls through to `super` so the
    # Bucket-1 Flight redirect row / Rails 302 is unchanged (AC1). Same-origin
    # redirects collapse to a path (mirroring `Ruact::Controller`); external
    # origins keep the absolute URL.
    def redirect_to(options = {}, response_options = {})
      return super unless __ruact_function_call?

      render json: { "$redirect" => __ruact_redirect_directive(url_for(options)) }
    end

    private

    # AC6 — append `Accept` to the `Vary` response header for non-GET requests
    # (idempotent, preserves any host-set `Vary`).
    def __ruact_set_vary_on_accept!
      return if request.get? || request.head?

      values = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
      values << "Accept" unless values.any? { |value| value.casecmp?("Accept") }
      response.headers["Vary"] = values.join(", ")
    end

    # Collapse a redirect target to a path for same-origin URLs (the common
    # `redirect_to @record` case); keep the absolute URL for external origins
    # so a cross-origin redirect (e.g. a payment provider) survives. Mirrors the
    # same-origin handling in {Ruact::Controller#redirect_to}.
    def __ruact_redirect_directive(url)
      uri = ::URI.parse(url)
      if uri.host &&
         (uri.host != request.host ||
          (uri.port && uri.port != request.port) ||
          (uri.scheme && uri.scheme != request.scheme))
        return url
      end

      path = uri.path.nil? || uri.path.empty? ? "/" : uri.path
      path += "?#{uri.query}" if uri.query
      path += "##{uri.fragment}" if uri.fragment
      path
    rescue ::URI::InvalidURIError
      url
    end

    # Raw discriminator — does the request's `Accept` header equal
    # `application/json`? This is exactly what the 8.1 runtime sends on every
    # `_makeRef` fetch (Bucket 2 — imperative `await createPost(...)`).
    # Browser navigation and `<form>` submits never use that exact header, and
    # Flight requests send `text/x-component`.
    #
    # Deliberately NOT `request.format`: the Rails format negotiation is
    # influenced by path extensions (`/posts.json`) and `params[:format]`,
    # neither of which may flip the bucket. This is the verb-AGNOSTIC header
    # check; the semantic predicate {#__ruact_function_call?} layers the verb
    # rule on top.
    def __ruact_json_accept?
      request.headers["Accept"] == "application/json"
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
    # Review patch (2026-06-08, round 3) — `Ruact::ConfigurationError` is never
    # rendered as a structured server-action error: configuration invariants
    # (most notably the upload-guard ordering check) must stay LOUD setup
    # failures. Folding one into an ordinary `_ruact_server_action_error` 500
    # on a JSON function call would disguise a deploy-blocking misconfiguration
    # as a transient runtime error. It re-raises so Rails' default error
    # handling surfaces it.
    def __ruact_render_structured_error?(error)
      return false if request.get? || request.head?
      return false if error.is_a?(Ruact::ConfigurationError)

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
  end
end
