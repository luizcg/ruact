# frozen_string_literal: true

module Ruact
  # Story 13.2 (FR96) — the canonical record-reference primitive: a **signed,
  # scoped, expiring** SignedGlobalID token instead of a raw id or attribute
  # dump.
  #
  # A controller that puts `@post.id` (or an attribute hash) into props hands
  # the client a *forgeable, unscoped, non-expiring* reference: swap `id: 7`
  # for `id: 8` and, if the action trusts `params[:id]` raw, it reaches a record
  # it should not. {Ruact.signed_global_id} mints a `SignedGlobalID` instead —
  # HMAC-signed by the app secret (tamper-proof), bound to a `for:` purpose
  # (scoped to one use-site), and `expires_in:`-bounded — and
  # {Ruact.locate_signed} resolves it back, raising
  # {Ruact::InvalidSignedGlobalIDError} (→ a clean 4xx) on a tampered, expired,
  # or wrong-purpose token. This is the structural antidote to forged-reference
  # attacks, the inbound-safety counterpart to the serialize-only invariant
  # (Story 13.1).
  #
  # This is **opt-in and explicit** — it follows the same grain as
  # `ruact_props` (an explicit allowlist, not auto-detection). The developer
  # reaches for the helper; ruact never silently rewrites every
  # `ActiveRecord::Base` in props, and never auto-coerces inbound params into
  # records.
  #
  # @example Outbound — sign a reference in props, resolve it in an action
  #   # controller producing props
  #   def edit
  #     @post_ref = Ruact.signed_global_id(@post, for: :post_edit, expires_in: 1.hour)
  #   end
  #
  #   # server function receiving the reference back from the client
  #   def update
  #     post = Ruact.locate_signed(params[:post_ref], for: :post_edit)
  #     post.update!(post_params)
  #   end
  module SignedReferences
    # Sentinel marking "the caller omitted this keyword", kept distinct from an
    # explicit `nil`. Omission falls back to the configured default and, failing
    # that, raises loudly (AC1: "omitting both is a loud error, not a silent
    # insecure default"). An explicit `expires_in: nil` is honored as a
    # deliberate, reviewed non-expiring token.
    UNSET = Object.new
    def UNSET.inspect = "Ruact::SignedReferences::UNSET"
    UNSET.freeze
    private_constant :UNSET

    # Mint a `SignedGlobalID` token string for a record, scoped to a `for:`
    # purpose and bounded by `expires_in:`.
    #
    # @param record [GlobalID::Identification] an ActiveRecord (or any
    #   GlobalID-locatable) record — anything responding to `#to_sgid`.
    # @param for [Symbol, String] the purpose binding the token to one
    #   use-site. Omitted → {Ruact::Configuration#signed_global_id_default_purpose};
    #   if neither is set (or it resolves to `nil`), raises {Ruact::Error} —
    #   ruact refuses to sign an unscoped reference.
    # @param expires_in [ActiveSupport::Duration, nil] token lifetime. Omitted
    #   → {Ruact::Configuration#signed_global_id_default_expires_in}; if neither
    #   is set, raises {Ruact::Error}. Pass an explicit `nil` to deliberately
    #   mint a non-expiring token (a reviewed per-call choice).
    # @return [String] the signed token, safe to serialize as a prop (it is a
    #   plain `String`, so the Flight serializer carries it unchanged).
    # @raise [Ruact::Error] when the record is not GlobalID-locatable, or when a
    #   purpose/expiry cannot be resolved.
    def signed_global_id(record, for: UNSET, expires_in: UNSET)
      __ruact_require_global_id!
      purpose = __ruact_resolve_purpose(binding.local_variable_get(:for))
      expiry  = __ruact_resolve_expiry(expires_in)

      unless record.respond_to?(:to_sgid)
        raise Ruact::Error,
              "Ruact.signed_global_id expects a GlobalID-locatable record (one responding to " \
              "#to_sgid, e.g. an ActiveRecord model); got #{record.class}."
      end

      record.to_sgid(for: purpose, expires_in: expiry).to_s
    end

    # Resolve a signed token back to its record, verifying signature, expiry,
    # and purpose. The inverse of {#signed_global_id}.
    #
    # @param token [String, nil] the signed token received from the client.
    # @param for [Symbol, String] the purpose the token must match — resolved
    #   the same way as {#signed_global_id} (omitted → config → raise).
    # @return [GlobalID::Identification] the located record.
    # @raise [Ruact::InvalidSignedGlobalIDError] when the token is tampered,
    #   expired, or scoped to a different purpose (`locate_signed` returns
    #   `nil`). The structured-error chain maps this to a clean 4xx — no
    #   `ActiveRecord::RecordNotFound` leak, no raw-id trust.
    # @raise [Ruact::Error] when a purpose cannot be resolved.
    def locate_signed(token, for: UNSET)
      __ruact_require_global_id!
      purpose = __ruact_resolve_purpose(binding.local_variable_get(:for))
      record  = GlobalID::Locator.locate_signed(token, for: purpose)
      return record unless record.nil?

      raise Ruact::InvalidSignedGlobalIDError,
            "Signed reference could not be verified for purpose #{purpose.inspect} " \
            "(it may be tampered, expired, or scoped to a different purpose)."
    end

    private

    # Lazy-require globalid only when a signed-reference helper is actually
    # called — the gem keeps a single hard runtime dependency (nokogiri) and
    # stays loadable in pure-Ruby contexts (mirrors the class-name-string
    # matching in ErrorRendering that avoids requiring ActiveRecord at load).
    # globalid ships with every Rails app, so a host never hits the rescue.
    def __ruact_require_global_id!
      require "global_id"
    rescue LoadError
      raise Ruact::Error,
            "Ruact signed references require the `globalid` gem, which ships with Rails. " \
            "Add `gem \"globalid\"` to your Gemfile if you are running ruact outside a Rails app."
    end

    # Purpose must ALWAYS be present — an unscoped token is never acceptable, so
    # both omission-without-default AND an explicit `for: nil` raise.
    def __ruact_resolve_purpose(arg)
      resolved = arg.equal?(UNSET) ? Ruact.config.signed_global_id_default_purpose : arg
      return resolved unless resolved.nil?

      raise Ruact::Error,
            "Ruact signed references require a purpose: pass `for:` (a Symbol/String scoping the " \
            "token to one use-site) or set `Ruact.config.signed_global_id_default_purpose`. " \
            "Refusing to sign or resolve an unscoped reference."
    end

    # Expiry distinguishes omission from a deliberate `nil`. An explicit value
    # (including `nil` → non-expiring) is honored; pure omission falls to the
    # configured default and, if that too is unset, raises — never a silent
    # non-expiring token.
    def __ruact_resolve_expiry(arg)
      return arg unless arg.equal?(UNSET)

      configured = Ruact.config.signed_global_id_default_expires_in
      return configured unless configured.nil?

      raise Ruact::Error,
            "Ruact.signed_global_id requires an expiry: pass `expires_in:` (an " \
            "ActiveSupport::Duration like `15.minutes`, or an explicit `nil` to deliberately mint a " \
            "non-expiring token) or set `Ruact.config.signed_global_id_default_expires_in`. " \
            "Refusing to silently mint a non-expiring reference."
    end
  end

  extend SignedReferences
end
