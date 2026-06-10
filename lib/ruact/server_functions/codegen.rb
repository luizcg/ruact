# frozen_string_literal: true

require "json"
require "ruact/server_functions/name_bridge"

module Ruact
  module ServerFunctions
    # Renders the snapshot Hash into the TypeScript module emitted to
    # `app/javascript/.ruact/server-functions.ts`. Pure string-building plus a
    # single write-if-changed call.
    #
    # The output of {.render} MUST be byte-identical to the JS-side codegen in
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
      # no `ruby_symbol`) and renders `_makeServerFunction(descriptor)` calls
      # instead of `_makeRef("<sym>")`. {.render} dispatches on `version` so
      # the v1 (registry-driven) path stays byte-for-byte untouched.
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
      # Runtime behavior is unchanged — `_makeRef` always resolves with the
      # JSON-decoded value (or `null` for empty bodies). The intersection is
      # a TYPE-ONLY surface: when callers `await` the result, they see
      # `Promise<unknown>`; when React invokes the function from a
      # `<form action>` prop, the `Promise<void>` overload is selected and
      # the return value is discarded by React.
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
      QUERY_PARAMS_SIGNATURE = "(params: Record<string, unknown>) => Promise<unknown>"

      # Story 8.2 — fixed re-export appended AFTER the per-function block.
      # Emitted in BOTH branches (empty + populated registry) so
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
      # (`functions[].js_identifier == ");\nevil();_makeRef("foo`) would
      # otherwise inject TS at module top level.
      VALID_JS_IDENTIFIER = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      ALLOWED_KINDS = %w[action query].freeze

      # JS comments (both `//` line comments and `/* … */` block comments via
      # the spec's LineTerminator production) end on LF, CR, U+2028, and U+2029.
      # A snapshot value that smuggles any of these would break out of the
      # leading comment header in the emitted module. The reviewer's Pass-2
      # finding noted that an earlier `/[\r\n]/` guard missed the two Unicode
      # line separators; the regex is widened here and a parity test in
      # `server-functions-codegen.test.mjs` keeps both renderers in sync.
      LINE_TERMINATORS = /[\r\n  ]/

      class << self
        # Renders +snapshot+ into the TS module text. Pure; no I/O.
        #
        # @param snapshot [Hash] result of {Ruact::ServerFunctions::Snapshot.dump};
        #   must contain `:version`, `:generated_at`, `:functions` (with string-keyed
        #   entries).
        # @return [String] TS module bytes, terminated by a single trailing newline.
        # @raise [Ruact::ConfigurationError] when an entry fails any of the
        #   snapshot-trust-boundary guards (line-break in version /
        #   generated_at, invalid identifier shape, reserved JS word, kind
        #   outside {ALLOWED_KINDS}, or duplicate `js_identifier` — mirror of
        #   the JS-side `validateSnapshot` per the 2026-05-14 Re-run patch).
        def render(snapshot)
          unless snapshot.is_a?(Hash)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot must be a Hash, got #{snapshot.class}"
          end

          version      = fetch_snapshot_key!(snapshot, :version, "version")
          generated_at = fetch_snapshot_key!(snapshot, :generated_at, "generated_at")
          functions    = fetch_snapshot_key!(snapshot, :functions, "functions")

          validate_metadata!(version, generated_at)

          return V2.render(version, generated_at, functions) if version.to_s == VERSION_V2.to_s

          validate_functions!(functions)

          io = +""
          io << "// AUTO-GENERATED by vite-plugin-ruact (Story 8.0a). DO NOT EDIT.\n"
          io << "// Source: tmp/cache/ruact/server-functions.json (version #{version})\n"
          io << "// Generated at: #{generated_at}\n"
          io << "import { _makeRef } from #{RUNTIME_IMPORT};\n"

          if functions.empty?
            io << "\n// (no server functions registered yet — Stories 8.1 / 9.1 populate)\n"
            # `noUnusedLocals` would otherwise flag the `_makeRef` import. The
            # `void` discard pattern keeps the import alive at zero runtime
            # cost; once an action/query is registered the export below
            # references `_makeRef` directly and this line is omitted.
            io << "void _makeRef;\n"
          else
            io << "\n"
            functions.each do |entry|
              io << render_export(entry)
            end
          end

          # Story 8.2 — `revalidate()` is always available, so the
          # re-export lands in both branches (empty registry + populated).
          # The codegen owns the canonical import path
          # `@/.ruact/server-functions` and is the only stable surface devs
          # are told to import from in the docs (per the Story 8.0 ADR);
          # without this line, devs would need a second import statement
          # from a less-stable runtime-package path.
          io << "\n"
          io << REVALIDATE_REEXPORT

          io
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

        def render_export(entry)
          js_id    = entry["js_identifier"] || entry[:js_identifier]
          kind     = (entry["kind"] || entry[:kind]).to_s
          ruby_sym = entry["ruby_symbol"] || entry[:ruby_symbol]

          signature = kind == "query" ? QUERY_SIGNATURE : ACTION_SIGNATURE

          "export const #{js_id}: #{signature} =\n  _makeRef(#{json_escape(ruby_sym.to_s)});\n"
        end

        # Pass-2 patch 2026-05-14 — wrap raw `KeyError` from `Hash#fetch` so
        # the rake / Railtie call sites get a consistent `Ruact::ConfigurationError`
        # for every snapshot-shape failure, not a mixture of error classes.
        def fetch_snapshot_key!(snapshot, sym_key, str_key)
          return snapshot[sym_key] if snapshot.key?(sym_key)
          return snapshot[str_key] if snapshot.key?(str_key)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: snapshot is missing required key " \
                "#{sym_key.inspect} (or #{str_key.inspect}); the bridge JSON is " \
                "corrupted — regenerate via `bin/rails ruact:server_functions:generate`."
        end

        # Mirror of the JS-side `validateSnapshot` (2026-05-14 Re-run parity
        # fix). The Ruby renderer also reads from the on-disk JSON bridge in
        # the rake-task and Railtie paths, so the same trust-boundary guards
        # belong here.
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

        def validate_functions!(functions)
          unless functions.is_a?(Array)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: snapshot.functions must be an " \
                  "Array, got #{functions.class}"
          end

          seen = {}
          functions.each do |entry|
            unless entry.is_a?(Hash)
              raise Ruact::ConfigurationError,
                    "ruact server-function codegen: snapshot.functions entry is " \
                    "not a Hash: #{entry.inspect}"
            end
            js_id    = entry["js_identifier"] || entry[:js_identifier]
            kind     = (entry["kind"] || entry[:kind]).to_s
            ruby_sym = entry["ruby_symbol"] || entry[:ruby_symbol]

            validate_ruby_symbol!(ruby_sym)
            validate_js_identifier!(js_id, ruby_sym)
            validate_kind!(kind, ruby_sym)
            validate_not_reserved!(js_id, ruby_sym)
            validate_no_duplicate!(seen, js_id)
            seen[js_id] = true
          end
        end

        # Pass-2 patch 2026-05-14 — without this guard, a missing or empty
        # `ruby_symbol` on a snapshot entry would render `_makeRef("")` and
        # silently emit an export that can never resolve at runtime (the
        # placeholder rejects on call but the empty string is a meaningless
        # registration name). Treat as a corrupt-snapshot signal.
        def validate_ruby_symbol!(ruby_sym)
          return if ruby_sym.is_a?(String) && !ruby_sym.empty?
          return if ruby_sym.is_a?(Symbol) && !ruby_sym.empty?

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: snapshot.functions entry has " \
                "missing or empty ruby_symbol (got #{ruby_sym.inspect}); the " \
                "bridge JSON is corrupted — regenerate via " \
                "`bin/rails ruact:server_functions:generate`."
        end

        def validate_js_identifier!(js_id, ruby_sym)
          return if js_id.is_a?(String) && js_id.match?(VALID_JS_IDENTIFIER)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen rejected a snapshot entry: " \
                "ruby_symbol=#{ruby_sym.inspect} js_identifier=#{js_id.inspect} " \
                "is not a valid JS identifier (must match #{VALID_JS_IDENTIFIER.inspect}). " \
                "The snapshot JSON is corrupted or was hand-edited — regenerate via " \
                "`bin/rails ruact:server_functions:generate`."
        end

        def validate_kind!(kind, ruby_sym)
          return if ALLOWED_KINDS.include?(kind)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: snapshot.functions entry has " \
                "invalid kind #{kind.inspect} (must be \"action\" or \"query\") " \
                "for ruby_symbol=#{ruby_sym.inspect}"
        end

        def validate_not_reserved!(js_id, ruby_sym)
          if NameBridge::RESERVED_JS_IDENTIFIERS.include?(js_id)
            raise Ruact::ConfigurationError,
                  "ruact server-function codegen: js_identifier #{js_id.inspect} " \
                  "is a reserved JS word — ruby_symbol=#{ruby_sym.inspect} would " \
                  "emit an invalid TS module. NameBridge should have rejected this; " \
                  "regenerate via `bin/rails ruact:server_functions:generate`."
          end

          # Story 8.2 R12 — even if NameBridge somehow lets a reserved
          # ruact name through (e.g. a hand-edited bridge JSON), the
          # codegen MUST refuse — otherwise the rendered module would
          # bind `revalidate` / `_makeRef` twice (once via the
          # re-export / import, once via the action `export const`)
          # and crash at module load.
          return unless NameBridge::RESERVED_BY_RUACT.include?(js_id)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: js_identifier #{js_id.inspect} " \
                "is reserved by the ruact runtime/codegen surface (would clash " \
                "with the module's `revalidate` re-export or `_makeRef` import) — " \
                "ruby_symbol=#{ruby_sym.inspect} cannot be exported. NameBridge " \
                "should have rejected this; regenerate via " \
                "`bin/rails ruact:server_functions:generate`."
        end

        def validate_no_duplicate!(seen, js_id)
          return unless seen.key?(js_id)

          raise Ruact::ConfigurationError,
                "ruact server-function codegen: duplicate js_identifier " \
                "#{js_id.inspect} in snapshot — two entries would emit " \
                "conflicting `export const` declarations. The snapshot JSON is " \
                "corrupted or was hand-edited — regenerate via " \
                "`bin/rails ruact:server_functions:generate`."
        end

        # Wraps `ruby_symbol` in a JSON-escaped string literal so backslashes,
        # double quotes, and control characters cannot break out of the
        # `_makeRef("<here>")` argument.
        def json_escape(str)
          JSON.dump(str)
        end
      end
    end
  end
end

# Story 9.3 — the route-driven (version-2) renderer lives in its own module so
# the v1 singleton class stays within its size budget. Required after the
# constants above are defined; `Codegen.render` delegates to it on version 2.
require_relative "codegen_v2"
