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

    # The RFC 7231 §5.3.1 qvalue grammar: `0`, `0.` + up to three digits, `1`,
    # or `1.` + up to three zeros. Anything else (leading dot, leading zero,
    # exponent, over-precision, out-of-range) is malformed.
    QVALUE_FORMAT = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/
    private_constant :QVALUE_FORMAT

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
    #
    # Review patch (2026-06-08, round 3) — the Accept header is parsed into
    # media ranges instead of a raw `include?("application/json")` substring
    # test, which mistook `application/jsonp` and `application/json;q=0` for a
    # JSON-Accept request and was case-sensitive. A request counts as
    # JSON-Accept only when it carries an `application/json` media range (matched
    # case-insensitively on token boundaries) with a positive q-value. Because
    # {#__ruact_function_call?} feeds Story 9.2's discriminator, a loose match
    # here would route ordinary requests into Ruact's structured payload.
    def __ruact_json_accept?
      accept = request.headers["Accept"]
      return false if accept.nil? || accept.empty?

      __ruact_split_unquoted(accept, ",").any? { |range| __ruact_json_media_range?(range) }
    end

    # Does a single Accept media range name `application/json` with a usable
    # q-value? Media types are matched case-insensitively on token boundaries,
    # so `application/jsonp` is rejected. A range with unbalanced/unterminated
    # quotes is rejected outright (review patch round 5) rather than being
    # treated as default-quality JSON. The q-value must be a valid HTTP qvalue
    # ({QVALUE_FORMAT}) AND positive, so `q=0`, out-of-range (`q=2`, `q=1.5`),
    # and malformed (`q=.5`, `q=01`, `q=1e-1`, `q=0.1234`) values are rejected.
    def __ruact_json_media_range?(range)
      return false unless __ruact_balanced_quotes?(range)

      media_type, *parameters = __ruact_split_unquoted(range, ";").map(&:strip)
      return false if media_type.nil? || media_type.empty?
      return false unless media_type.casecmp?("application/json")

      __ruact_accept_quality(parameters).positive?
    end

    # Extract a media range's q-value (relative quality). Absent → 1.0; present
    # but not a valid qvalue → a rejecting 0.0.
    def __ruact_accept_quality(parameters)
      q_param = parameters.find { |parameter| parameter.downcase.start_with?("q=") }
      return 1.0 if q_param.nil?

      value = q_param.split("=", 2).last
      return 0.0 unless value.match?(QVALUE_FORMAT)

      value.to_f
    end

    # Split `string` on `delimiter`, ignoring delimiters inside a double-quoted
    # span and honoring HTTP quoted-pair (`\`) escaping (review patches rounds
    # 4–5). An HTTP Accept parameter value may be a quoted-string containing
    # commas/semicolons or an escaped quote (`application/json;note="a\",b";q=0`);
    # a naive split would break it apart and let a fragment masquerade as a JSON
    # media range with a default q of 1.0.
    def __ruact_split_unquoted(string, delimiter)
      parts = []
      current = +""
      in_quotes = false
      escaped = false
      string.each_char do |char|
        if escaped
          current << char
          escaped = false
        elsif char == "\\" && in_quotes
          current << char
          escaped = true
        elsif char == '"'
          in_quotes = !in_quotes
          current << char
        elsif char == delimiter && !in_quotes
          parts << current
          current = +""
        else
          current << char
        end
      end
      parts << current
      parts
    end

    # Are all double quotes in `string` balanced (quoted-pair `\"` aware)? A
    # range with an unterminated quoted string is malformed and must not be
    # parsed as a default-quality JSON media range (review patch round 5).
    def __ruact_balanced_quotes?(string)
      in_quotes = false
      escaped = false
      string.each_char do |char|
        if escaped
          escaped = false
        elsif char == "\\" && in_quotes
          escaped = true
        elsif char == '"'
          in_quotes = !in_quotes
        end
      end
      !in_quotes
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
    # Review patch (2026-06-08, round 3) — it is ALSO invoked from
    # {Ruact::ServerFunctions::ErrorRendering#__ruact_render_action_error}, so
    # the inversion surfaces even on the request shape that never reaches the
    # guard: an oversized tokenless POST on an inverted host is rejected by
    # CSRF first, but the rescue chain re-asserts this invariant and the
    # `ConfigurationError` propagates rather than a quiet 403.
    #
    # Review patch (2026-06-08, round 5) — gated on
    # {#__ruact_upload_guard_applicable?}: GET/HEAD requests (where the guard
    # never fires — D2) no longer raise, keeping page loads byte-for-byte (AC1)
    # even on an inverted host. The misordering surfaces on the first NON-GET
    # (guarded) request instead. This supersedes the round-2 "fail on the first
    # GET page load" behavior noted above.
    def __ruact_verify_upload_guard_precedence!
      # Review patch (2026-06-08, round 5) — D2/AC1: the upload guard never
      # fires on GET/HEAD, so there is no 413-before-CSRF invariant to enforce
      # on those requests. Skipping the check here keeps GET page loads
      # byte-for-byte even on an otherwise-inverted host; the misordering
      # surfaces loudly on the first NON-GET (guarded) request instead. This
      # SUPERSEDES the round-2 "fail on the first GET page load" behavior.
      return unless __ruact_upload_guard_applicable?

      # Review patch (2026-06-08, round 4) — `max_upload_bytes = nil` is the
      # documented carve-out that disables the gem-side cap, so there is no
      # 413-before-CSRF invariant left to protect. Skip the ordering check
      # entirely rather than failing an inverted host that has intentionally
      # opted out of the guard.
      return if Ruact.config.max_upload_bytes.nil?
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

    # Inspection of the compiled before-callback chain for the CURRENT request/
    # action. Returns true only when BOTH callbacks are present, the
    # `verify_authenticity_token` callback is ordered ahead of the upload
    # guard, AND that CSRF callback actually APPLIES to this request.
    #
    # Review patch (2026-06-08, round 4) — round 3 narrowed detection to
    # UNCONDITIONAL CSRF callbacks to avoid false positives, but that created a
    # false NEGATIVE: a conditional callback that DOES apply to the current
    # action (`protect_from_forgery prepend: true, only: [:create]` on
    # `create`, or `if: -> { true }`) still runs ahead of the guard yet went
    # unflagged. The detector now evaluates the callback's `if`/`unless`
    # conditions against the controller, so an active condition is caught and
    # an inactive one (`only: [:other]`, `if: -> { false }`) is not. This is no
    # longer purely static — it reads `action_name` and any request-derived
    # state the conditions touch — but both call sites (the guard and the
    # rescue path) run inside a live request.
    def __ruact_csrf_precedes_upload_guard?
      before_callbacks = self.class._process_action_callbacks
                             .select { |callback| callback.kind == :before }
      filters = before_callbacks.map(&:filter)
      guard_index = filters.index(:__ruact_enforce_upload_limit!)
      csrf_index = filters.index(:verify_authenticity_token)
      return false if guard_index.nil? || csrf_index.nil?
      return false unless csrf_index < guard_index

      __ruact_callback_applies?(before_callbacks[csrf_index])
    end

    # Does a compiled before-callback apply to the current request/action? All
    # of its `@if` conditions must hold and none of its `@unless` conditions
    # may. Rails compiles `only:`/`except:` into
    # `AbstractController::Callbacks::ActionFilter` entries in these same
    # arrays, so this covers all four condition forms.
    def __ruact_callback_applies?(callback)
      callback.instance_variable_get(:@if).all? { |condition| __ruact_condition_met?(condition) } &&
        callback.instance_variable_get(:@unless).none? { |condition| __ruact_condition_met?(condition) }
    end

    # Evaluate a single callback condition against this controller. Symbols are
    # sent as methods, Procs are `instance_exec`'d (arity-aware), and
    # `ActionFilter` (and any condition object responding to `match?`/`call`)
    # is asked whether it matches the current action.
    def __ruact_condition_met?(condition)
      case condition
      when Symbol then send(condition)
      when Proc   then condition.arity.zero? ? instance_exec(&condition) : instance_exec(self, &condition)
      else
        if condition.respond_to?(:match?)
          condition.match?(self)
        elsif condition.respond_to?(:call)
          condition.call(self)
        else
          condition
        end
      end
    end
  end
end
