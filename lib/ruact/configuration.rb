# frozen_string_literal: true

module Ruact
  # Holds gem-wide configuration. Instantiated once via Ruact.config.
  # Configure via `Ruact.configure { |c| c.attr = value }` in an initializer.
  #
  # Frozen after `Ruact.configure` returns (Story 7.3) — direct post-boot
  # mutation (`Ruact.config.attr = value` outside the block) raises
  # `Ruact::ConfigurationError` with the offending attribute, the caller's
  # file:line, and the suggested fix. Re-calling `Ruact.configure` after boot
  # replaces the configuration atomically and emits a `[ruact]` warning.
  class Configuration
    # The set of public attributes; new attributes added here automatically
    # inherit the freeze contract via the `define_method` writer below.
    ATTRIBUTES = %i[
      manifest_path
      strict_serialization
      suspense_timeout
      vite_dev_server
      dev_error_payload_enabled
      max_upload_bytes
      query_route_prefix
      query_parent_controller
      signed_global_id_default_purpose
      signed_global_id_default_expires_in
      shadcn_compatible_versions
      layout
    ].freeze

    # @!attribute [r] manifest_path
    #   @return [String, nil] Path to react-client-manifest.json.
    #     Defaults to Rails.root.join("public/react-client-manifest.json") when nil.
    #
    # @!attribute [r] strict_serialization
    #   @return [Boolean] When true, objects without explicit ruact_props declaration
    #     raise Ruact::SerializationError. Defaults to false in development, true in production.
    #
    # @!attribute [r] suspense_timeout
    #   @return [Float] Seconds before a deferred Suspense chunk times out. Default: 5.0.
    #
    # @!attribute [r] vite_dev_server
    #   @return [String] Base URL of the Vite dev server. Default: "http://localhost:5173".
    #
    # @!attribute [r] dev_error_payload_enabled
    #   @return [Boolean, nil] Story 8.4 — When true, server-action failures
    #     respond with a verbose JSON payload (action name, error class,
    #     message, split backtrace, contextual suggestion, validation errors).
    #     When false, the wire body carries only the four baseline fields
    #     (`_ruact_server_action_error`, `action_name`, `error_class`,
    #     `message`) so React components can render their own UI without
    #     accidental backtrace leakage. Default `nil` — the error-rendering
    #     layer resolves nil to `Rails.env.development? || Rails.env.test?`,
    #     keeping the Configuration trivially constructible in non-Rails specs.
    #   @example Force production-shape errors in development
    #     Ruact.configure { |c| c.dev_error_payload_enabled = false }
    #
    # @!attribute [r] max_upload_bytes
    #   @return [Integer, nil] Story 8.5 — upper bound (in bytes) on the
    #     `Content-Length` of `multipart/form-data` and
    #     `application/x-www-form-urlencoded` requests dispatched to a
    #     `Ruact::Server` mutation route. When the inbound `Content-Length`
    #     exceeds this value, the server concern raises
    #     `Ruact::UploadTooLargeError` BEFORE Rack's multipart parser runs,
    #     producing a 413 with the Story 8.4 structured error body.
    #     Default: `10 * 1024 * 1024` (10 MB). Set to `nil` to disable the
    #     gem-side guard — typical when a reverse proxy (`client_max_body_size`)
    #     or host middleware already owns the operational cap. Chunked-transfer
    #     requests (no `Content-Length` header) bypass the guard regardless of
    #     this setting; the action body is responsible for any belt-and-suspenders
    #     check via `params[:file].size` / `params[:file].byte_size` in that case.
    #   @note This is a controller-level "fail fast at the boundary" knob, not
    #     a stream-safety guarantee — Rack's multipart parser will still buffer
    #     bodies up to its own limits before the guard rejects. For very large
    #     uploads route through Active Storage Direct Upload or a presigned S3
    #     URL; see `website/docs/api/server-actions.md` "File uploads" section.
    #   @example Raise the limit to 25 MB
    #     Ruact.configure { |c| c.max_upload_bytes = 25 * 1024 * 1024 }
    #   @example Disable the gem-side guard (reverse proxy owns the cap)
    #     Ruact.configure { |c| c.max_upload_bytes = nil }
    #
    # @!attribute [r] query_route_prefix
    #   @return [String] Story 9.4 — URL prefix under which the `ruact_queries`
    #     routing macro draws one named GET route per public query method
    #     (default `"/q"` → `GET /q/<jsIdentifier>`). Must be a String starting
    #     with `/` and without a trailing slash (the macro joins prefix and
    #     identifier with `/`). Changing the prefix is configuration, never code.
    #   @example Mount queries under /api/queries
    #     Ruact.configure { |c| c.query_route_prefix = "/api/queries" }
    #
    # @!attribute [r] query_parent_controller
    #   @return [String] Story 9.4 — class NAME of the controller the gem's
    #     internal query dispatch controller inherits from (default
    #     `"ApplicationController"` — the Devise `parent_controller` pattern).
    #     Kept as a String and constantized lazily at route-draw time, NOT at
    #     configure time: `ApplicationController` does not exist when the gem
    #     loads. The host's REAL callback chain (`authenticate_user!`, tenant
    #     scoping, Pundit) runs before any query class is instantiated (FR89).
    #   @example Dispatch queries through an API base controller
    #     Ruact.configure { |c| c.query_parent_controller = "Api::BaseController" }
    #
    # @!attribute [r] signed_global_id_default_purpose
    #   @return [Symbol, String, nil] Story 13.2 (FR96) — the default `for:`
    #     purpose `Ruact.signed_global_id` / `Ruact.locate_signed` use when the
    #     call omits `for:`. A purpose scopes a signed reference to one
    #     use-site so a token minted for editing a post cannot be replayed
    #     against, say, a delete endpoint. Default `nil` — when neither the
    #     call nor this config supplies a purpose, the helper raises
    #     `Ruact::Error` rather than sign an unscoped token (the "developer
    #     forgot" path is a loud error, never a silent insecure default).
    #     Prefer a per-call `for:` when use-sites differ; set this only for an
    #     app-wide default purpose.
    #   @example Set an app-wide default purpose
    #     Ruact.configure { |c| c.signed_global_id_default_purpose = :ruact_ref }
    #
    # @!attribute [r] signed_global_id_default_expires_in
    #   @return [ActiveSupport::Duration, nil] Story 13.2 (FR96) — the default
    #     `expires_in:` `Ruact.signed_global_id` uses when the call omits
    #     `expires_in:`. Must be an `ActiveSupport::Duration` (e.g. `15.minutes`)
    #     — globalid calls `#from_now` on it. Default `nil` — when neither the
    #     call nor this config supplies an expiry, the helper raises
    #     `Ruact::Error` rather than mint a non-expiring token. To deliberately
    #     mint a non-expiring token, pass an explicit `expires_in: nil` at the
    #     call site (a reviewed per-call choice), never via this default.
    #   @example Set an app-wide default expiry
    #     Ruact.configure { |c| c.signed_global_id_default_expires_in = 1.hour }
    #
    # @!attribute [r] shadcn_compatible_versions
    #   @return [Array<Integer>] Story 10.5 — the shadcn/ui MAJOR versions the
    #     `ruact:scaffold` generator is regression-tested against. When the
    #     generator detects an installed shadcn major (best-effort, from the
    #     host `package.json`) that is NOT in this list, it emits a warning
    #     (never a hard stop) that the generated components may import from
    #     outdated `@/components/ui/*` paths. Must be a non-empty Array of
    #     Integers. Default `[1, 2]` (the majors tested at gem-release time).
    #     A dev who has manually verified a newer major adds it here to
    #     suppress the warning — the documented "override" path.
    #   @example Allow shadcn v3 once you have verified it
    #     Ruact.configure { |c| c.shadcn_compatible_versions = [1, 2, 3] }
    #
    # @!attribute [r] layout
    #   @return [Symbol, Boolean, String] Which document wrapper a ruact page's
    #     HTML response is rendered into. The Flight response shape
    #     (`text/x-component`) is never affected — this is only about the
    #     full-document render a browser gets on a normal navigation.
    #
    #     - `:auto` (default) — render through the host app's own layout when
    #       that layout is ruact-ready (it calls `ruact_js_assets`), otherwise
    #       fall back to the gem's built-in shell. Migration-safe, and the
    #       mechanism is the guarantee: `:auto` INSPECTS the layout's source and
    #       never renders it speculatively, so a layout that has never run on a
    #       ruact page cannot be executed just to discover it is unmigrated.
    #     - `true` — always render through the controller's normal Rails layout.
    #       **This is a sharp opt-in:** unlike `:auto` it RENDERS the layout and
    #       judges the result, so an unmigrated layout that depends on state a
    #       ruact action never sets (a `@page_title` ivar, an expected
    #       `content_for`) will raise from your own layout rather than degrade.
    #       Use it when the layout is genuinely ready but `:auto` cannot tell —
    #       typically because the helper is called from a partial.
    #     - a String — always render through that named layout (e.g. `"ruact"`).
    #     - `false` — always render the gem's built-in minimal shell.
    #
    #     The layout path exists because the document `<head>` belongs to the
    #     host app: `stylesheet_link_tag`, favicons, fonts, analytics and any
    #     `<head>`-writing gem only reach the page when Rails' own layout owns
    #     the document. The built-in shell carries no stylesheet slot, so under
    #     `layout = false` a ruact page renders with no app CSS at all.
    #
    #     A ruact-ready layout is a normal Rails layout that also calls
    #     `<%= ruact_js_assets %>` (which emits the React root's bootstrap entry
    #     tags and the per-render Flight payload). `rails generate ruact:install`
    #     writes one; `rails ruact:doctor` reports a layout that is missing it.
    #   @note A ruact view is rendered in its own pass (it produces the component
    #     tree), so `content_for` declared inside the view does NOT reach the
    #     layout. Set document metadata from the controller instead.
    #   @example Opt in explicitly — e.g. a layout that reaches the helper
    #     through a partial, which `:auto`'s source read cannot see
    #     Ruact.configure { |c| c.layout = true }
    #   @example Keep the pre-0.0.9 built-in shell
    #     Ruact.configure { |c| c.layout = false }
    ATTRIBUTES.each do |attr|
      attr_reader attr

      define_method("#{attr}=") do |value|
        if frozen?
          location = caller_locations(1, 1).first
          raise Ruact::ConfigurationError, build_error_message(attr, location)
        end
        validate_attribute_value!(attr, value)
        instance_variable_set("@#{attr}", value)
      end
    end

    # Build a fresh Configuration. When +template+ is given, dup every public
    # attribute from it so the draft is mutable — used by `Ruact.configure` for
    # atomic-replacement cloning. The dup is required because the template is
    # always a published (frozen) Configuration with deep-frozen attribute
    # values, and AC1 requires the DSL inside the configure block to behave
    # identically regardless of whether this is the first call or a later one
    # (including idiomatic in-place mutation of inherited values).
    #
    # `dup` is safe for every supported attribute type: Strings produce an
    # unfrozen copy; nil/true/false/Numerics/Symbols dup to themselves (they
    # are inherently immutable, so the dup is a no-op).
    #
    # @param template [Ruact::Configuration, nil] optional source to clone from
    def initialize(template: nil)
      if template
        ATTRIBUTES.each do |attr|
          value = template.public_send(attr)
          # Procs are immutable from the outside. Duping creates a different Proc
          # instance, breaking identity comparisons across re-configurations.
          # Procs are inherently re-entrant safe (no mutable internal state
          # surface) so the dup is unnecessary; the freeze at seal! time is enough.
          cloned = value.is_a?(Proc) ? value : value.dup
          instance_variable_set("@#{attr}", cloned)
        end
      else
        @manifest_path        = nil
        @strict_serialization = begin
          Rails.env.production?
        rescue StandardError
          false
        end
        @suspense_timeout     = 5.0
        @vite_dev_server      = "http://localhost:5173"
        @dev_error_payload_enabled = nil
        @max_upload_bytes = 10 * 1024 * 1024
        @query_route_prefix = "/q"
        @query_parent_controller = "ApplicationController"
        @signed_global_id_default_purpose = nil
        @signed_global_id_default_expires_in = nil
        @shadcn_compatible_versions = [1, 2]
        @layout = :auto
      end
    end

    private

    # Internal — called by `Ruact.configure` and `Ruact.config` (via
    # `__send__(:seal!)`) immediately before publication. Deep-freezes every
    # attribute value so the shallow `Object#freeze` on the Configuration
    # cannot be bypassed by in-place mutation of an attribute value (e.g.
    # `Ruact.config.manifest_path.replace`) after publication. Returns self
    # (frozen).
    #
    # Values remain mutable inside the `Ruact.configure` block (AC1: the DSL
    # inside the block is unchanged; the freeze happens after the block
    # returns, not before). Only on `seal!` are values deep-frozen.
    #
    # Defined as `private` so it does not appear on the public API surface
    # of `Ruact::Configuration` (AC1/AC7/AC9: public API surface unchanged).
    # External callers reaching into `Ruact.config.seal!` get a NoMethodError.
    #
    # @api private
    # @return [Ruact::Configuration] self, frozen
    def seal!
      ATTRIBUTES.each do |attr|
        value = public_send(attr)
        next if value.nil? || value.frozen?

        # Story 8.3 review — Procs CAN be frozen (`.freeze` flips the frozen
        # flag; no operational effect on `.call`). Freezing in place preserves
        # object identity (vital for code that compares a Proc-valued attribute
        # across re-configurations) AND keeps the deep-freeze contract honest —
        # a later `.freeze` would otherwise silently no-op an already-frozen
        # reference, but a caller probing `frozen?` would see the right answer.
        if value.is_a?(Proc)
          value.freeze
        else
          instance_variable_set("@#{attr}", value.dup.freeze)
        end
      end
      freeze
    end

    # Story 8.5 review patch — attribute-specific writer-time validation. The
    # generic writer otherwise stores any value, which then surfaces as a
    # generic 500 (`Integer <= String` etc.) on the FIRST in-flight request
    # instead of a configuration-time error. Limit the surface to attributes
    # whose runtime contract is narrower than "any value" — currently only
    # `max_upload_bytes` (must be nil or a non-negative Integer). Other
    # attributes keep their pre-existing "store any value" contract.
    #
    # Negative integers would otherwise turn into a global 413 — every
    # request with a Content-Length above zero exceeds the configured limit.
    # Booleans, Strings, Floats, Symbols turn into a non-comparable type
    # error at request time. Both cases land here at boot/configure time
    # with a legible message pointing at the offending value.
    def validate_attribute_value!(attr, value)
      case attr
      when :max_upload_bytes        then validate_max_upload_bytes!(value)
      when :query_route_prefix      then validate_query_route_prefix!(value)
      when :query_parent_controller then validate_query_parent_controller!(value)
      when :shadcn_compatible_versions then validate_shadcn_compatible_versions!(value)
      when :layout                     then validate_layout!(value)
      end
    end

    # The value selects a render strategy by identity (`:auto` / `true` /
    # `false`) or names a layout (String). Anything else would otherwise be
    # treated as "not false" and reach `render_to_string(layout: <value>)`,
    # where a Symbol layout name or a stray nil surfaces as a confusing
    # first-request 500 instead of a boot-time error. `nil` is rejected on
    # purpose: "no layout" is spelled `false`, so a nil left over from a
    # conditional in the initializer is a mistake, not a silent shell fallback.
    def validate_layout!(value)
      return if [:auto, true, false].include?(value)
      return if value.is_a?(String) && !value.empty?

      raise Ruact::ConfigurationError,
            "Ruact::Configuration#layout must be :auto, true, false, or a non-empty String " \
            "layout name; got #{value.inspect} (#{value.class.name}). " \
            ":auto renders through the app layout when it calls ruact_js_assets and falls back " \
            "to ruact's built-in shell otherwise; false always uses the built-in shell."
    end

    def validate_max_upload_bytes!(value)
      return if value.nil?
      return if value.is_a?(Integer) && value >= 0

      raise Ruact::ConfigurationError,
            "Ruact::Configuration#max_upload_bytes must be nil or a non-negative Integer; " \
            "got #{value.inspect} (#{value.class.name}). " \
            "Set to nil to disable the gem-side guard, or pass a positive Integer (bytes)."
    end

    # Story 9.4 — the prefix is joined with the jsIdentifier as
    # `"#{prefix}/#{js}"` at route-draw time, so a missing leading slash would
    # draw a relative path and a trailing slash would draw `//`. Both are
    # configuration-time errors, not first-request 500s.
    def validate_query_route_prefix!(value)
      unless value.is_a?(String) && value.start_with?("/")
        raise Ruact::ConfigurationError,
              "Ruact::Configuration#query_route_prefix must be a String starting with \"/\"; " \
              "got #{value.inspect} (#{value.class.name})."
      end
      return unless value.length > 1 && value.end_with?("/")

      raise Ruact::ConfigurationError,
            "Ruact::Configuration#query_route_prefix must not end with \"/\" " \
            "(the ruact_queries macro joins the prefix and the query identifier with \"/\"); " \
            "got #{value.inspect}."
    end

    # Story 9.4 — kept as a String on purpose: the name is constantized lazily
    # at route-draw time (`ApplicationController` does not exist when the gem
    # loads or when the initializer runs).
    def validate_query_parent_controller!(value)
      return if value.is_a?(String) && !value.empty?

      raise Ruact::ConfigurationError,
            "Ruact::Configuration#query_parent_controller must be a non-empty String " \
            "(the controller class NAME, constantized lazily at route-draw time); " \
            "got #{value.inspect} (#{value.class.name})."
    end

    # Story 10.5 — the scaffold generator validates the detected shadcn major
    # against this list (`Array#include?`), so a non-Array would raise at the
    # first scaffold run instead of at boot, and an empty Array would make every
    # detected major "incompatible" (a global false warning). Both are
    # configuration-time errors. Element-type strictness (Integer-only majors)
    # is enforced too — a `["2"]` typo would silently never match a detected
    # Integer major and warn on every run.
    def validate_shadcn_compatible_versions!(value)
      unless value.is_a?(Array) && !value.empty?
        raise Ruact::ConfigurationError,
              "Ruact::Configuration#shadcn_compatible_versions must be a non-empty Array " \
              "of major-version Integers (e.g. [1, 2]); " \
              "got #{value.inspect} (#{value.class.name})."
      end
      return if value.all?(Integer)

      raise Ruact::ConfigurationError,
            "Ruact::Configuration#shadcn_compatible_versions must contain only Integer " \
            "major versions (e.g. [1, 2]); got #{value.inspect}."
    end

    def build_error_message(attr, location)
      <<~MSG.strip
        ruact: cannot mutate Ruact::Configuration##{attr} after initialization.
          Attempted at: #{location.path}:#{location.lineno}
          Wrap the change in Ruact.configure { |c| c.#{attr} = ... } in config/initializers/ruact.rb and restart the process.
          Why: Ruact::Configuration is frozen after initialization (Story 7.3) so that runtime config drift cannot cause environment-dependent behavior.
      MSG
    end
  end
end
