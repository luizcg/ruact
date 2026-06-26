# frozen_string_literal: true

require "active_support/concern"
require_relative "server_functions/validation_errors"

module Ruact
  # Story 13.3 (FR98) — the per-request validation-error collector, shared by
  # {Ruact::Server} (Bucket-2 JSON-body injection + redirect flash stash) and
  # {Ruact::Controller} (page-render `errors` prop + redirect-back flash read).
  #
  # This is the **opt-in** half of the Inertia-style `errors` round-trip
  # (design (B), the explicit-allowlist grain that 13.1/13.2 reinforced — NO
  # auto-injection, NO globally reserved prop on every response). A host action
  # opts in with a single call after its save attempt:
  #
  #   def create
  #     @post = Post.new(post_params)
  #     if @post.save
  #       redirect_to @post
  #     else
  #       ruact_errors(@post)            # registers {attr => [full messages]}
  #       render :new                    # (Bucket 1) or fall through (Bucket 2)
  #     end
  #   end
  #
  # Because the canonical shape derives from `record.errors` (empty on a valid
  # record), the SAME `ruact_errors(@post)` call yields `{}` on success and the
  # populated map on failure — the "always present, same code path" invariant of
  # AC1, delivered per-action without reserving a global prop name or disturbing
  # the Story 9.2 Bucket-2 `204 No Content` contract for an untouched collector.
  #
  # The reader form (no argument) returns the always-present hash for binding to
  # a form component on the page render:
  #
  #   <PostForm post={@post} errors={ruact_errors} />
  module ValidationErrorsCollector
    extend ActiveSupport::Concern

    # Flash key the Bucket-1 redirect-back round-trip stashes the canonical
    # errors under (single-use, session-backed — the exact Inertia semantics).
    RUACT_ERRORS_FLASH_KEY = :ruact_errors

    # `view_assigns` keys (ivar names without the leading `@`) that must NEVER
    # serialize into a Bucket-2 body: the two collector internals (Rails only
    # filters a fixed set of `@_`-named ivars, not every `@__`-prefixed one), and
    # the reserved `errors` output key itself (a stray dev ivar literally named
    # `@errors` is dropped so it can neither clobber the round-trip key nor trip
    # strict serialization — the collector is the source of truth).
    RESERVED_ASSIGN_KEYS = %w[__ruact_errors __ruact_errors_touched errors].freeze

    # Sentinel distinguishing the COLLECT call (`ruact_errors(record)`, argument
    # given) from the READ call (`ruact_errors`, no argument). `nil` is a valid
    # collect argument (it normalizes to `{}`), so it cannot be the sentinel.
    NOT_GIVEN = Object.new
    private_constant :NOT_GIVEN

    included do
      # Expose the reader to the view so a template can bind
      # `errors={ruact_errors}` on a component. Guarded for non-controller hosts
      # (which never reach the page-render path).
      helper_method :ruact_errors if respond_to?(:helper_method)
    end

    # Dual-purpose helper.
    #
    #   ruact_errors(@post)  → COLLECT: normalize the record's errors into the
    #     canonical `{attr => [full messages]}` shape, merge it into the
    #     per-request collector, mark the collector touched, and return the
    #     normalized hash (so it can also be used inline).
    #   ruact_errors         → READ: return the always-present collector (`{}` by
    #     default), for binding to a form component on the page render.
    #
    # Merging across multiple records is additive per attribute (later calls
    # union their messages onto earlier ones), so an action validating several
    # records surfaces them under one `errors` object.
    #
    # @overload ruact_errors(record)
    #   @param record [#errors, ActiveModel::Errors, Hash, nil] the failed record
    #   @return [Hash{String=>Array<String>}] the normalized errors for +record+
    # @overload ruact_errors
    #   @return [Hash{String=>Array<String>}] the always-present collector
    def ruact_errors(record = NOT_GIVEN)
      return __ruact_errors if record.equal?(NOT_GIVEN)

      normalized = ServerFunctions::ValidationErrors.normalize(record)
      @__ruact_errors_touched = true
      __ruact_errors.merge!(normalized) do |_attribute, existing, incoming|
        existing | incoming
      end
      normalized
    end

    private

    # The per-request collector. A private ivar (NOT a `view_assigns` ivar) so it
    # never collides with the dev's own assigns during Bucket-2 serialization.
    def __ruact_errors
      @__ruact_errors ||= {}
    end

    # Whether `ruact_errors` was called in a writing form this request (or the
    # collector was seeded from a redirect-back flash). Gates the Bucket-2
    # injection so an UNTOUCHED collector preserves the 9.2 `204 No Content`
    # contract — a populated `{}` (opted-in success) is still "touched".
    def __ruact_errors_touched?
      @__ruact_errors_touched == true
    end

    # Stash the canonical errors in `flash` so they survive a Bucket-1
    # redirect-back (the re-render is a fresh GET). No-op when the collector was
    # never touched, or when the host has no usable session/flash (an API-only
    # host without sessions degrades to the Bucket-2 body path rather than
    # crashing — AC4 constraint).
    def __ruact_stash_errors_in_flash
      return unless __ruact_errors_touched?
      return unless respond_to?(:flash)

      flash[RUACT_ERRORS_FLASH_KEY] = __ruact_errors
    rescue StandardError
      nil
    end

    # Seed the collector from a redirect-back flash on the re-rendered GET so the
    # reader exposes the surviving errors as a page-render prop. `flash` is
    # single-use (Rails sweeps it after this request), so the prop does not
    # persist beyond the re-render.
    def __ruact_read_errors_from_flash
      return unless respond_to?(:flash)

      stashed = flash[RUACT_ERRORS_FLASH_KEY]
      return if stashed.nil?

      @__ruact_errors_touched = true
      __ruact_errors.merge!(ServerFunctions::ValidationErrors.normalize(stashed))
    rescue StandardError
      nil
    end
  end
end
