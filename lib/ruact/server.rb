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
require_relative "server_functions/name_bridge"
require_relative "validation_errors_collector"

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
  # Both bodies live in {Ruact::ServerFunctions::ErrorRendering} (Story 9.9 —
  # this concern is now the sole home; the v1 endpoint that previously shared it
  # was demolished). Dual-bucket response negotiation (ivar serialization,
  # `$redirect`, 204, `Vary: Accept`) is Story 9.2; this concern only
  # contributes the discrimination predicate 9.2 will reuse.
  module Server
    extend ActiveSupport::Concern

    include Ruact::ServerFunctions::ErrorRendering
    include Ruact::ValidationErrorsCollector

    included do
      # Story 8.5 salvage — prepended so the size check wins the race against
      # every other callback, including `verify_authenticity_token`.
      prepend_before_action :__ruact_enforce_upload_limit!

      # Story 9.2 AC6 — `Vary: Accept` on every non-GET SUCCESS shape. The same
      # URL + verb serves two bodies discriminated solely on `Accept`, so a
      # cache MUST vary on it (never serve Flight to a JSON caller or vice-versa).
      # Set in BOTH a `before_action` and an `after_action` (review rounds 1–2),
      # because either callback alone has a gap:
      #   - the `after_action` APPENDS to a host-set `Vary` (preserving it), but
      #     is skipped when a `before_action` performs the response (e.g. an auth
      #     `before_action` that `redirect_to`s a Bucket-2 call);
      #   - the `before_action` covers that halt case (it runs ahead of the
      #     host's own before-callbacks), but a later `response.headers["Vary"] =`
      #     in the action would clobber it.
      # Together they cover the 200 ivar-JSON / 204 / `$redirect` / Bucket-1
      # Flight shapes (incl. before-callback redirects). The method is
      # idempotent. Error responses (413/403/500) may still omit it — they are
      # non-cacheable, not dual representations.
      #
      # Documented limitation (accepted 2026-06-09): a host `before_action` that
      # BOTH overwrites `Vary` AND performs the response (e.g.
      # `response.headers["Vary"] = "Cookie"; redirect_to "/login"` in one
      # before-callback) leaves the final response without `Accept` — the Ruact
      # before-action set it first, the host clobbered it, and Rails skips the
      # after-action on the before-halt. This combination is contrived (real
      # auth callbacks don't reassign `Vary` while redirecting); a callback can't
      # guarantee the final header unconditionally, and a Rack-level mechanism
      # was judged not worth the complexity for this edge.
      before_action :__ruact_set_vary_on_accept!
      after_action  :__ruact_set_vary_on_accept!

      # Story 15.0 (F6) — dev-only legibility warning: an action that registers
      # validation errors (`ruact_errors(record)`) and then performs an EXPLICIT
      # render on a function-call request bypasses `default_render`, so the
      # registered errors silently vanish from the JSON body. The warning names
      # the opt-out; it never fires on the documented-correct patterns (Bucket-1
      # page render, redirect on either bucket, the fall-through itself, or an
      # action that never touches the collector). Log-only — bodies and statuses
      # are byte-identical in every environment.
      after_action :__ruact_warn_errors_injection_opt_out!

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

    # Story 9.3 — the JS-identifier rename escape hatch (AC4). Naming is
    # derived from the route table by default ({Ruact::ServerFunctions::RouteSource});
    # when two routes collide in the merged JS namespace the codegen fails loudly
    # at boot, and this macro is how a host breaks the tie (or simply prefers a
    # different name):
    #
    #   class PostsController < ApplicationController
    #     include Ruact::Server
    #     ruact_function_name :publish_all, as: "publishEverything"
    #   end
    #
    # The override is keyed by ACTION name (string) and read by the codegen via
    # {#__ruact_function_name_overrides}. The target identifier is validated at
    # class-load time against the same JS-identifier shape + reserved-word rules
    # the codegen enforces, so a bad override fails at boot, never at codegen.
    module ClassMethods
      # JS identifier shape — mirror of {Ruact::ServerFunctions::Codegen::VALID_JS_IDENTIFIER}
      # (kept local so the concern does not depend on the codegen module).
      RUACT_VALID_JS_IDENTIFIER = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      # @param action [Symbol, String] the controller action whose generated
      #   server-function name is being overridden.
      # @param as [Symbol, String] the JS identifier to emit instead of the
      #   derived one.
      # @raise [Ruact::ConfigurationError] when +as+ is not a valid JS identifier
      #   or collides with a reserved word / a name the runtime already binds.
      def ruact_function_name(action, as:)
        js = as.to_s
        unless js.match?(RUACT_VALID_JS_IDENTIFIER)
          raise Ruact::ConfigurationError,
                "ruact_function_name :#{action}, as: #{as.inspect} — " \
                "\"#{js}\" is not a valid JS identifier (must match #{RUACT_VALID_JS_IDENTIFIER.inspect})"
        end
        if Ruact::ServerFunctions::NameBridge::RESERVED_JS_IDENTIFIERS.include?(js) ||
           Ruact::ServerFunctions::NameBridge::RESERVED_BY_RUACT.include?(js)
          raise Ruact::ConfigurationError,
                "ruact_function_name :#{action}, as: #{as.inspect} — " \
                "\"#{js}\" is a reserved JS word or is already bound by the ruact runtime " \
                "(`_makeServerFunction` / `_makeQuery` / `revalidate` / `useQuery`); pick another name"
        end

        __ruact_function_name_overrides[action.to_s] = js
      end

      # The action-name → js-identifier override map for this controller,
      # consulted by {Ruact::ServerFunctions::RouteSource}. Per-controller (not
      # inherited) — overrides describe the host's own actions.
      #
      # @return [Hash{String=>String}]
      def __ruact_function_name_overrides
        @__ruact_function_name_overrides ||= {}
      end
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

      # Story 13.3 (FR98) — the collector's framework-internal ivars (and a stray
      # dev `@errors`) are dropped from the serialized assigns; Rails' own
      # `view_assigns` only filters a fixed set of `@_` ivars, not every `@__`
      # one (see {Ruact::ValidationErrorsCollector::RESERVED_ASSIGN_KEYS}).
      assigns = view_assigns.except(*ValidationErrorsCollector::RESERVED_ASSIGN_KEYS)

      # Story 15.0 (F6) — reaching this branch means ruact itself is producing
      # the function-call response (fall-through: injection, plain JSON, or
      # 204), so the opt-out warning must stay silent. Set AFTER `view_assigns`
      # is captured above so the flag ivar never leaks into the serialized body.
      @__ruact_function_response_owned = true

      # Story 13.3 (FR98, AC3) — when the host opted into the validation-error
      # round-trip (`ruact_errors(@record)` was called this request), inject the
      # collected errors under the reserved JSON key `"errors"` alongside the
      # serialized ivars, even on an otherwise-empty assigns set: an opted-in
      # success must still surface `{"errors": {}}` so the client's `await`
      # result carries `result.errors` on a single code path.
      if __ruact_errors_touched?
        payload = ServerFunctions::BucketTwoPayload.build(
          assigns, strict: Ruact.config.strict_serialization
        )
        payload["errors"] = __ruact_errors
        return render(json: payload)
      end

      # An UNTOUCHED collector changes nothing — the 9.2 `204 No Content`
      # empty-Bucket-2 contract is preserved.
      return head(:no_content) if assigns.empty?

      render json: ServerFunctions::BucketTwoPayload.build(
        assigns, strict: Ruact.config.strict_serialization
      )
    end

    # Story 9.2 AC3 (D2) — on a function-call request, `redirect_to` surfaces as
    # a JSON redirect directive — body `"$redirect" => "<path>"` (the runtime
    # follows it client-side; re-targeting/following is Story 9.3) instead of a
    # 302 or a Flight redirect row. Any other request shape falls through to
    # `super` so the Bucket-1 Flight redirect row / Rails 302 is unchanged (AC1).
    #
    # Review round 1 — reuses Rails' OWN redirect machinery
    # (`_compute_redirect_to_location`, `_ensure_url_is_http_header_safe`,
    # `_enforce_open_redirect_protection`) so the nil-check, header-safety, and
    # open-redirect protection (`allow_other_host` / `raise_on_open_redirects`)
    # match Bucket 1 / stock Rails exactly — a cross-host `redirect_to` raises
    # `UnsafeRedirectError` instead of leaking an external `$redirect`. Same-
    # origin targets collapse to a path; an allowed external origin keeps the
    # absolute URL.
    def redirect_to(options = {}, response_options = {})
      return super unless __ruact_function_call?

      raise ActionController::ActionControllerError, "Cannot redirect to nil!" unless options
      raise AbstractController::DoubleRenderError if response_body

      allow_other_host = response_options.delete(:allow_other_host)
      location = _compute_redirect_to_location(request, options)
      _ensure_url_is_http_header_safe(location)
      location = _enforce_open_redirect_protection(location, allow_other_host: allow_other_host)

      # Story 15.0 (F6) — a Bucket-2 `redirect_to` is a ruact-owned response
      # (`$redirect`; registered errors ride flash), not an injection opt-out.
      @__ruact_function_response_owned = true
      render json: { "$redirect" => __ruact_redirect_path(location) }
    end

    private

    # AC6 — append `Accept` to the `Vary` response header for non-GET requests
    # (idempotent, preserves any host-set `Vary`). A host `Vary: *` wildcard is
    # left as-is (review round 2): per HTTP, `Vary` is either `*` (varies on
    # everything) OR a field-name list — `*, Accept` is invalid/weaker.
    def __ruact_set_vary_on_accept!
      return if request.get? || request.head?

      values = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
      return if values.include?("*")

      values << "Accept" unless values.any? { |value| value.casecmp?("Accept") }
      response.headers["Vary"] = values.join(", ")
    end

    # Collapse a (already open-redirect-validated) location to a path for
    # same-origin URLs (the common `redirect_to @record` case); keep the
    # absolute URL for an allowed external origin so a cross-origin redirect
    # (e.g. a payment provider, with `allow_other_host: true`) survives. Mirrors
    # the same-origin handling in {Ruact::Controller#redirect_to}.
    def __ruact_redirect_path(url)
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

    # Story 15.0 (F6) — the dev-only opt-out warning. Fires when ALL hold:
    # development environment, the request is a function call
    # ({#__ruact_function_call?}), the collector was touched
    # (`ruact_errors(record)` ran this request), and the response was produced
    # by an EXPLICIT host render — i.e. neither {#default_render}'s
    # function-call branch nor the Bucket-2 {#redirect_to} set
    # `@__ruact_function_response_owned`. In that shape the registered errors
    # were silently dropped from the JSON body (the F6 finding).
    #
    # The four MUST-NOT-warn guardrails fall out of the predicate:
    #   (a) Bucket-1 `render :new` — not a function call;
    #   (b) `redirect_to` on either bucket — Bucket-2 sets the owned flag,
    #       Bucket-1 is not a function call;
    #   (c) the fall-through — `default_render` sets the owned flag;
    #   (d) an untouched collector — `__ruact_errors_touched?` is false.
    # The exception path never reaches here either: a raise aborts the
    # after_action chain before this hook runs (`rescue_from` renders outside
    # it), so a structured error payload is not misread as an opt-out.
    def __ruact_warn_errors_injection_opt_out!
      return unless __ruact_development?
      return unless __ruact_function_call?
      return unless __ruact_errors_touched?
      return if @__ruact_function_response_owned

      Rails.logger&.warn(
        "[ruact] #{self.class.name}##{action_name} called `ruact_errors` and then rendered " \
        "explicitly on a function-call request — the registered validation errors were NOT " \
        "injected into the JSON response. Remove the explicit render and let the action fall " \
        "through (ruact injects `errors` into the body), or surface them on a page render with " \
        "`errors={ruact_errors}` / carry them through a `redirect_to` (flash)."
      )
    end

    # @return [Boolean] true only in a real Rails development environment
    #   (mirrors {Ruact::ManifestResolver.development?}).
    def __ruact_development?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:development?) &&
        Rails.env.development?
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
