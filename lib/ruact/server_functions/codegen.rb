# frozen_string_literal: true

require "json"
require "ruact/server_functions/name_bridge"

module Ruact
  module ServerFunctions
    # Renders the route-driven (version-2) snapshot Hash into the TypeScript
    # module emitted to `app/javascript/.ruact/server-functions.ts`. Pure
    # string-building plus a single write-if-changed call.
    #
    # Story 9.9 — the v1 (registry / `_makeRef`) render path was demolished;
    # {.render} now dispatches only the version-2 (route-driven) shape. The
    # actual rendering lives in the nested {V2} module (kept separate so the
    # singleton class stays within its size budget).
    #
    # The output of {V2.render} MUST be byte-identical to the JS-side codegen in
    # `gem/vendor/javascript/vite-plugin-ruact/server-functions-codegen.mjs`.
    # The cross-implementation parity test under
    # `gem/vendor/javascript/vite-plugin-ruact/server-functions-codegen.test.mjs`
    # asserts this invariant; if it fails, fix the offending side rather than
    # normalizing in the assertion (Story 8.0a Task 8.5).
    module Codegen
      # Bumped only when the rendered shape changes. Used by tests to assert
      # cross-implementation parity without coupling to the literal byte string.
      VERSION = 1

      # Story 9.3 — the route-driven snapshot schema. A version-2 snapshot
      # carries route-derived entries (`http_method` + `path` + `segments`,
      # no `ruby_symbol`) and renders `_makeServerFunction(descriptor)` calls.
      VERSION_V2 = 2

      RUNTIME_IMPORT = '"ruact/server-functions-runtime"'

      # Story 8.2 (2026-05-16, refined 2026-05-17 per review patch R1) —
      # ACTION_SIGNATURE is a TS intersection type with TWO call signatures:
      #
      #   1. `(args?: FormData | Record<string, unknown>) => Promise<unknown>`
      #      — for direct callers (`await createPost({...})` /
      #      `await createPost(formData)` / event handlers), preserving the
      #      JSON-decoded response value.
      #   2. `(formData: FormData) => Promise<void>` — assignable to
      #      `@types/react@19.x`'s `<form action>` prop, which is typed as
      #      `(formData: FormData) => void | Promise<void>`. TS rejects
      #      `Promise<unknown>` → `Promise<void>` even via the void-discard
      #      rule (Promise generics are invariant), so the intersection is
      #      required to make `<form action={createPost}>` typecheck DIRECTLY
      #      against the codegen-emitted module — no call-site cast, no
      #      wrapper closure.
      #
      # See the 2026-05-17 entry in `gem/docs/internal/decisions/server-functions-api.md`
      # ("R1 — intersection-type refinement") for the option (a)→(a′)
      # evolution and the empirical typecheck-probe that motivated it.
      # Query signatures stay narrow because queries are never reachable via
      # `<form action>` (read-only via `useQuery`).
      ACTION_SIGNATURE =
        "((args?: FormData | Record<string, unknown>) => Promise<unknown>) " \
        "& ((formData: FormData) => Promise<void>)"
      QUERY_SIGNATURE  = "() => Promise<unknown>"

      # Story 9.5 — a query method that declares keyword arguments (FR88
      # params) gets the param-accepting signature; one with no kwargs keeps
      # the bare {QUERY_SIGNATURE}. Queries are read-only (never reachable via
      # `<form action>`), so neither widens to the action intersection.
      #
      # Story 13.4 — {QUERY_PARAMS_SIGNATURE}'s open `Record<string, unknown>`
      # is now the FALLBACK only: emitted for a pre-13.4 snapshot entry that
      # carries the `accepts_params` boolean but no structured `params`, and for
      # a `**keyrest`-only query (open by design). A query whose entry carries
      # the structured `params` metadata gets a typed object literal built from
      # the declared keys instead (see {V2.render_query_export}).
      QUERY_PARAMS_SIGNATURE = "(params: Record<string, unknown>) => Promise<unknown>"

      # Story 13.4 — the VALUE type of every typed query param. `Method#parameters`
      # exposes only names + required/optional (never types or default values),
      # so per-param scalar precision is not reflection-honest; this is the exact
      # FR88 query-string wire contract instead (the kwargs sanitizer in
      # `query_dispatch.rb` accepts only these). Keys and optionality ARE exact,
      # which is what kills the `Record<string, unknown>`/`any` gap (named keys,
      # missing-required and unknown-key become compile errors). Per-param scalar
      # narrowing is deferred to a future explicit param-type DSL.
      QUERY_PARAM_VALUE_TYPE = "string | number | boolean | null"

      # Story 8.2 — fixed re-export appended AFTER the per-function block.
      # Emitted in BOTH branches (empty + populated) so
      # `import { revalidate } from "@/.ruact/server-functions"` works on
      # day one of any host app. Ruby + JS codegens emit byte-identically.
      REVALIDATE_REEXPORT = "export { revalidate } from #{RUNTIME_IMPORT};\n".freeze

      # Story 9.5 — the `useQuery` hook re-export, appended (after
      # {REVALIDATE_REEXPORT}) ONLY when the v2 snapshot carries query entries.
      # Gating on query presence keeps the action-only and empty v2 modules
      # byte-identical to their Story 9.3 output (minimal churn); a host that
      # has no queries cannot call `useQuery` on anything anyway. Ruby + JS
      # codegens emit this byte-identically.
      USEQUERY_REEXPORT = "export { useQuery } from #{RUNTIME_IMPORT};\n".freeze

      # JS identifier shape — same as `NameBridge::VALID_SYMBOL` but expressed
      # in JS-identifier terms (leading letter / underscore / `$`, then alnum
      # / underscore / `$`). The codegen validates every entry it consumes
      # because the JSON bridge is a trust boundary — a malformed snapshot
      # would otherwise inject TS at module top level.
      VALID_JS_IDENTIFIER = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      ALLOWED_KINDS = %w[action query].freeze

      # JS comments (both `//` line comments and `/* … */` block comments via
      # the spec's LineTerminator production) end on LF, CR, U+2028, and U+2029.
      # A snapshot value that smuggles any of these would break out of the
      # leading comment header in the emitted module. The regex covers both
      # Unicode line separators (written as explicit escapes); a parity test
      # keeps both renderers in sync.
      LINE_TERMINATORS = /[\r\n\u2028\u2029]/

      class << self
        # Renders +snapshot+ into the TS module text. Pure; no I/O. Story 9.9 —
        # only the route-driven (version-2) shape is supported.
        #
        # @param snapshot [Hash] result of {Snapshot.dump_v2}; must contain
        #   `:version`, `:generated_at`, `:functions` (string-keyed entries).
        # @return [String] TS module bytes, terminated by a single trailing newline.
        # @raise [Ruact::ConfigurationError] on a non-Hash snapshot, a missing
        #   required key, a non-v2 `version`, or any trust-boundary violation in
        #   {V2.render}.
        def render(snapshot)
          unless snapshot.is_a?(Hash)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot must be a Hash, got #{snapshot.class}"
          end

          version      = fetch_snapshot_key!(snapshot, :version, "version")
          generated_at = fetch_snapshot_key!(snapshot, :generated_at, "generated_at")
          functions    = fetch_snapshot_key!(snapshot, :functions, "functions")

          validate_metadata!(version, generated_at)

          unless version.to_s == VERSION_V2.to_s
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: unsupported snapshot version " \
                  "#{version.inspect} (only the route-driven version #{VERSION_V2} is " \
                  "supported as of Story 9.9); the bridge JSON is corrupted — " \
                  "regenerate via `bin/rails ruact:server_functions:generate`."
          end

          V2.render(version, generated_at, functions)
        end

        # Writes the rendered TS module to +output_path+, only if it changed.
        # See {Ruact::ServerFunctions::SnapshotWriter.write_if_changed!}.
        #
        # @param snapshot [Hash]
        # @param output_path [String, Pathname]
        # @return [Boolean] true if the file was written; false if unchanged.
        def generate_ts!(snapshot:, output_path:)
          SnapshotWriter.write_if_changed!(path: output_path, content: render(snapshot))
        end

        private

        # Wraps raw `KeyError` from `Hash#fetch` so call sites get a consistent
        # `Ruact::ConfigurationError` for every snapshot-shape failure.
        def fetch_snapshot_key!(snapshot, sym_key, str_key)
          return snapshot[sym_key] if snapshot.key?(sym_key)
          return snapshot[str_key] if snapshot.key?(str_key)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: snapshot is missing required key " \
                "#{sym_key.inspect} (or #{str_key.inspect}); the bridge JSON is " \
                "corrupted — regenerate via `bin/rails ruact:server_functions:generate`."
        end

        def validate_metadata!(version, generated_at)
          unless version.is_a?(Integer) || version.is_a?(String)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot.version must be an " \
                  "Integer or String, got #{version.class}"
          end
          if version.to_s.match?(LINE_TERMINATORS)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot.version contains a " \
                  "line break (LF, CR, U+2028, or U+2029) — would break out of " \
                  "the header comment; snapshot JSON is corrupted."
          end

          unless generated_at.is_a?(String)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot.generated_at must be " \
                  "a String, got #{generated_at.class}"
          end
          return unless generated_at.match?(LINE_TERMINATORS)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: snapshot.generated_at contains " \
                "a line break (LF, CR, U+2028, or U+2029) — would break out of " \
                "the header comment; snapshot JSON is corrupted."
        end
      end
    end
  end
end

# Story 9.3 — the route-driven (version-2) renderer lives in its own module so
# the v1 singleton class stays within its size budget. Required after the
# constants above are defined; `Codegen.render` delegates to it on version 2.
require_relative "codegen_v2"
