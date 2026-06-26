// Story 8.0a — server-functions codegen sidecar for vite-plugin-ruact.
//
// READ THIS COMMENT BEFORE EDITING. The TypeScript module emitted by this file
// MUST be byte-identical to what
// `gem/lib/ruact/server_functions/codegen.rb` produces. A cross-implementation
// parity test (`server-functions-codegen.test.mjs` → "Ruby parity") asserts
// this invariant. If you change emitted output here, change the Ruby side in
// lockstep — do NOT normalize differences in the assertion.
//
// The sidecar is wired into `index.js` via {@link installServerFunctionsHooks},
// which mutates the plugin's hook table to:
//   - register `resolve.alias["@"]` and `resolve.alias["ruact/server-functions-runtime"]`
//   - emit `app/javascript/.ruact/server-functions.ts` at buildStart
//   - watch `tmp/cache/ruact/server-functions.json` and re-emit on mtime change
//
// All exports here are also importable for unit testing (see the test file).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const RUNTIME_IMPORT_SPECIFIER = "ruact/server-functions-runtime";

export const VALID_JS_IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

// JS comment terminators per ECMAScript LineTerminator production: LF (\n),
// CR (\r), U+2028 (LINE SEPARATOR), U+2029 (PARAGRAPH SEPARATOR). A snapshot
// value containing any of these would break out of the leading `//` comment
// header. The Ruby `LINE_TERMINATORS` constant in `codegen.rb` mirrors this
// list; a snapshot containing a Unicode line separator must be rejected
// identically by both renderers (Pass-2 patch 2026-05-14).
function containsLineTerminator(s) {
  return /[\r\n\u2028\u2029]/.test(s);
}

// Mirror of Ruby `NameBridge::RESERVED_JS_IDENTIFIERS`. The Ruby side enforces
// this at controller load time (Story 8.1 / 9.1). The JS side re-enforces
// because the JSON bridge is an independent trust boundary — a hand-edited
// snapshot bypasses the Ruby check.
const RESERVED_JS_IDENTIFIERS = new Set([
  "arguments", "async", "await", "break", "case", "catch", "class", "const", "continue",
  "debugger", "default", "delete", "do", "else", "enum", "eval", "export", "extends", "false",
  "finally", "for", "function", "if", "implements", "import", "in", "instanceof", "interface",
  "let", "new", "null", "package", "private", "protected", "public", "return", "static", "super",
  "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield",
]);

// Story 8.2 R12 (2026-05-17) — names ALREADY bound at module top by the
// codegen itself: the runtime imports (`_makeServerFunction`, `_makeQuery`) and
// the re-exports (`revalidate`, `useQuery`). A snapshot that declared any as a
// `js_identifier` would emit a duplicate binding and crash at module-load time.
// Mirrors Ruby `NameBridge::RESERVED_BY_RUACT`. Story 9.5 added `_makeQuery` +
// `useQuery`; Story 9.9 removed the demolished v1 `_makeRef`.
const RESERVED_BY_RUACT = new Set([
  "_makeQuery",
  "_makeServerFunction",
  "revalidate",
  "useQuery",
]);

// Story 9.3 — the route-driven snapshot schema version + its verb allowlist.
// A version-2 snapshot renders `_makeServerFunction({...})` calls; as of Story
// 9.9 it is the only supported version. Mirrors Ruby `Codegen::VERSION_V2` /
// `V2_HTTP_METHODS`.
export const VERSION_V2 = 2;
const V2_HTTP_METHODS = new Set(["POST", "PUT", "PATCH", "DELETE"]);
// Story 9.5 — queries are GET-only (the 2026-06-02 ADR addendum restored HTTP
// GET semantics for queries). Mirrors Ruby `Codegen::V2::QUERY_HTTP_METHODS`.
const V2_QUERY_HTTP_METHODS = new Set(["GET"]);

// Story 13.4 — the VALUE type of every typed query param: the FR88 query-string
// wire union (keys + optionality are exact; per-param scalar precision is not
// reflection-honest and is deferred). Mirrors Ruby `Codegen::QUERY_PARAM_VALUE_TYPE`.
const QUERY_PARAM_VALUE_TYPE = "string | number | boolean | null";

/**
 * Absolute path to the placeholder runtime bundled inside the gem. Used as the
 * target of the `ruact/server-functions-runtime` Vite alias so host apps
 * resolve the import without any `npm install` step.
 *
 * @returns {string}
 */
export function runtimePackagePath() {
  return path.resolve(HERE, "..", "ruact-server-functions-runtime", "index.js");
}

/**
 * Validates the snapshot shape before rendering. The bridge JSON is a trust
 * boundary — a corrupted or hand-edited snapshot must fail loudly rather than
 * silently emit invalid TS. Mirrors the Ruby-side guarantees (kind allowlist,
 * reserved-word ban, duplicate js_identifier detection) so this side stays
 * safe when consumed standalone (e.g., `vite build` without the rake task).
 *
 * @param {unknown} snapshot
 */
// Story 9.3 — extracted so both the v1 ({@link validateSnapshot}) and v2
// ({@link validateSnapshotV2}) paths share the identical root-shape +
// metadata checks (and identical error messages → byte-stable across versions).
function validateMetadata(snapshot) {
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
    throw new Error(
      "ruact server-function codegen: snapshot is not an object — " +
        "the bridge JSON is corrupted; regenerate via " +
        "`bin/rails ruact:server_functions:generate`.",
    );
  }

  // Pass-2 patch 2026-05-14 — fail explicitly on missing root keys rather
  // than letting `undefined` reach the type/value checks below with an
  // opaque "X must be a string, got undefined" message.
  for (const k of ["version", "generated_at", "functions"]) {
    if (!(k in snapshot)) {
      throw new Error(
        `ruact server-function codegen: snapshot is missing required key "${k}"; ` +
          "the bridge JSON is corrupted — regenerate via " +
          "`bin/rails ruact:server_functions:generate`.",
      );
    }
  }

  const { version, generated_at } = snapshot;

  if (typeof version !== "number" && typeof version !== "string") {
    throw new Error(
      `ruact server-function codegen: snapshot.version must be a number or string, got ${typeof version}`,
    );
  }
  const versionStr = String(version);
  if (containsLineTerminator(versionStr)) {
    throw new Error(
      "ruact server-function codegen: snapshot.version contains a line break " +
        "(LF, CR, U+2028, or U+2029) — would break out of the header comment; " +
        "snapshot JSON is corrupted.",
    );
  }

  if (typeof generated_at !== "string") {
    throw new Error(
      `ruact server-function codegen: snapshot.generated_at must be a string, got ${typeof generated_at}`,
    );
  }
  if (containsLineTerminator(generated_at)) {
    throw new Error(
      "ruact server-function codegen: snapshot.generated_at contains a line break " +
        "(LF, CR, U+2028, or U+2029) — would break out of the header comment; " +
        "snapshot JSON is corrupted.",
    );
  }
}

/**
 * Renders the route-driven (version-2) snapshot Hash into the TS module text.
 * MUST stay byte-identical to {Ruact::ServerFunctions::Codegen.render}. Story
 * 9.9 demolished the v1 (registry / `_makeRef`) render path; only version 2 is
 * supported.
 *
 * @param {{ version: number, generated_at: string, functions: Array<{
 *   js_identifier: string, kind: string, http_method?: string, path?: string,
 *   segments?: string[]
 * }> }} snapshot
 * @returns {string}
 */
export function render(snapshot) {
  // The version peek is shape-guarded so a corrupt non-object snapshot still
  // falls through to the loud validation failure below.
  if (
    snapshot &&
    typeof snapshot === "object" &&
    !Array.isArray(snapshot) &&
    String(snapshot.version) === String(VERSION_V2)
  ) {
    return renderV2(snapshot);
  }

  // Any non-v2 snapshot is corrupt as of Story 9.9. validateMetadata still
  // produces a precise message for the common shape errors; otherwise reject
  // the unsupported version explicitly.
  validateMetadata(snapshot);
  throw new Error(
    `ruact server-function codegen: unsupported snapshot version ${JSON.stringify(snapshot.version)} ` +
      `(only the route-driven version ${VERSION_V2} is supported as of Story 9.9); the bridge ` +
      "JSON is corrupted — regenerate via `bin/rails ruact:server_functions:generate`.",
  );
}

/**
 * Story 9.3 — validates a version-2 (route-driven) snapshot. A v2 entry has no
 * `ruby_symbol`; it carries `http_method` + `path` + `segments`. Mirrors the
 * Ruby-side `validate_functions_v2!`.
 *
 * @param {unknown} snapshot
 */
function validateSnapshotV2(snapshot) {
  validateMetadata(snapshot);
  const { functions } = snapshot;

  if (!Array.isArray(functions)) {
    throw new Error(
      `ruact server-function codegen: snapshot.functions must be an array, got ${typeof functions}`,
    );
  }

  const seen = new Set();
  for (const fn of functions) {
    if (!fn || typeof fn !== "object" || Array.isArray(fn)) {
      throw new Error(
        `ruact server-function codegen: snapshot.functions entry is not an object: ${JSON.stringify(fn)}`,
      );
    }
    if (typeof fn.js_identifier !== "string" || !VALID_JS_IDENTIFIER.test(fn.js_identifier)) {
      throw new Error(
        "ruact server-function codegen rejected a v2 snapshot entry: " +
          `js_identifier=${JSON.stringify(fn.js_identifier)} is not a valid JS identifier ` +
          "(must match /^[A-Za-z_$][A-Za-z0-9_$]*$/). The snapshot JSON is corrupted.",
      );
    }
    if (RESERVED_JS_IDENTIFIERS.has(fn.js_identifier) || RESERVED_BY_RUACT.has(fn.js_identifier)) {
      throw new Error(
        `ruact server-function codegen: js_identifier "${fn.js_identifier}" is reserved — ` +
          "cannot be exported. The snapshot JSON is corrupted.",
      );
    }
    if (seen.has(fn.js_identifier)) {
      throw new Error(
        `ruact server-function codegen: duplicate js_identifier "${fn.js_identifier}" in snapshot.`,
      );
    }
    seen.add(fn.js_identifier);

    if (fn.kind !== "action" && fn.kind !== "query") {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" has invalid ` +
          `kind ${JSON.stringify(fn.kind)} (v2 entries are "action" or "query").`,
      );
    }
    // Story 9.5 — actions carry a mutation verb; queries are GET-only.
    const allowedMethods = fn.kind === "query" ? V2_QUERY_HTTP_METHODS : V2_HTTP_METHODS;
    if (!allowedMethods.has(fn.http_method)) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" has invalid ` +
          `http_method ${JSON.stringify(fn.http_method)} (must be one of ${JSON.stringify([...allowedMethods])}).`,
      );
    }
    if (typeof fn.path !== "string" || !fn.path.startsWith("/")) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" has invalid ` +
          `path ${JSON.stringify(fn.path)} (must be a string beginning with "/").`,
      );
    }
    if (containsLineTerminator(fn.path)) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" path contains a ` +
          "line break — would break out of the generated call; snapshot JSON is corrupted.",
      );
    }
    if (!Array.isArray(fn.segments) || !fn.segments.every((s) => typeof s === "string" && s.length > 0)) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" has invalid ` +
          `segments ${JSON.stringify(fn.segments)} (must be an array of non-empty strings).`,
      );
    }
    // Whole-token match (mirror Ruby) — `:id` must not satisfy `:id_extra`.
    const missing = fn.segments.filter(
      (s) => !new RegExp(`:${s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![A-Za-z0-9_])`).test(fn.path),
    );
    if (missing.length > 0) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" declares ` +
          `segment(s) ${JSON.stringify(missing)} absent from path ${JSON.stringify(fn.path)}; ` +
          "snapshot JSON is corrupted.",
      );
    }
    // Bidirectional: every dynamic `:param` in the path must be declared.
    const pathParams = (fn.path.match(/:[A-Za-z_][A-Za-z0-9_]*/g) || []).map((t) => t.slice(1));
    const undeclared = pathParams.filter((p) => !fn.segments.includes(p));
    if (undeclared.length > 0) {
      throw new Error(
        `ruact server-function codegen: v2 snapshot entry "${fn.js_identifier}" path ${JSON.stringify(fn.path)} ` +
          `has dynamic segment(s) ${JSON.stringify(undeclared)} not declared in segments; ` +
          "snapshot JSON is corrupted.",
      );
    }
    // Story 13.4 — the structured query `params` metadata is a trust boundary
    // (it becomes TS object keys). Mirrors Ruby `validate_params!`.
    if (fn.kind === "query") validateQueryParams(fn);
  }
}

function validateQueryParams(fn) {
  const params = fn.params;
  if (params === undefined || params === null) return; // falls back to accepts_params

  if (!Array.isArray(params)) {
    throw new Error(
      `ruact server-function codegen: v2 query entry "${fn.js_identifier}" has invalid ` +
        `params ${JSON.stringify(params)} (must be an array of { name, required } objects).`,
    );
  }
  for (const param of params) {
    if (!param || typeof param !== "object" || Array.isArray(param)) {
      throw new Error(
        `ruact server-function codegen: v2 query entry "${fn.js_identifier}" has a params ` +
          `element that is not an object: ${JSON.stringify(param)}; snapshot JSON is corrupted.`,
      );
    }
    if (typeof param.name !== "string" || param.name.length === 0 || containsLineTerminator(param.name)) {
      throw new Error(
        `ruact server-function codegen: v2 query entry "${fn.js_identifier}" has a params ` +
          `name ${JSON.stringify(param.name)} that is not a non-empty single-line string; ` +
          "snapshot JSON is corrupted.",
      );
    }
    if (typeof param.required !== "boolean") {
      throw new Error(
        `ruact server-function codegen: v2 query entry "${fn.js_identifier}" params name ` +
          `${JSON.stringify(param.name)} has a non-boolean \`required\` ${JSON.stringify(param.required)}; ` +
          "snapshot JSON is corrupted.",
      );
    }
  }
}

/**
 * Story 9.3 — renders a version-2 (route-driven) snapshot. MUST stay
 * byte-identical to the Ruby-side `Codegen.render_v2`.
 *
 * @param {object} snapshot
 * @returns {string}
 */
function renderV2(snapshot) {
  validateSnapshotV2(snapshot);
  const { version, generated_at, functions } = snapshot;

  const hasQuery = functions.some((fn) => fn.kind === "query");
  const hasAction = functions.some((fn) => fn.kind === "action");

  // Story 9.5 — import only what is used. Keep `_makeServerFunction` in the
  // empty case so the no-functions module stays byte-identical to Story 9.3.
  const imports = [];
  if (hasAction || functions.length === 0) imports.push("_makeServerFunction");
  if (hasQuery) imports.push("_makeQuery");

  let out = "";
  out += "// AUTO-GENERATED by vite-plugin-ruact (Story 9.3). DO NOT EDIT.\n";
  out += `// Source: Rails route table (version ${version})\n`;
  out += `// Generated at: ${generated_at}\n`;
  out += `import { ${imports.join(", ")} } from "${RUNTIME_IMPORT_SPECIFIER}";\n`;

  if (functions.length === 0) {
    out += "\n// (no server functions exposed yet — add a non-GET route on a Ruact::Server controller)\n";
    out += "void _makeServerFunction;\n";
  } else {
    out += "\n";
    for (const fn of functions) {
      out += renderExportV2(fn);
    }
  }
  out += "\n";
  out += `export { revalidate } from "${RUNTIME_IMPORT_SPECIFIER}";\n`;
  // Story 9.5 — `useQuery` re-export ONLY when queries are present (keeps the
  // action-only / empty modules byte-identical to Story 9.3).
  if (hasQuery) out += `export { useQuery } from "${RUNTIME_IMPORT_SPECIFIER}";\n`;
  return out;
}

function renderExportV2(fn) {
  if (fn.kind === "query") return renderQueryExportV2(fn);

  // The same intersection signature as v1 actions (Story 8.2). Mirrors
  // `Ruact::ServerFunctions::Codegen::ACTION_SIGNATURE`.
  const signature =
    "((args?: FormData | Record<string, unknown>) => Promise<unknown>) & ((formData: FormData) => Promise<void>)";
  const method = JSON.stringify(String(fn.http_method));
  const pathLit = JSON.stringify(String(fn.path));
  const segs = (fn.segments || []).map((s) => JSON.stringify(String(s))).join(", ");
  const descriptor = `{ method: ${method}, path: ${pathLit}, segments: [${segs}] }`;
  return (
    `export const ${fn.js_identifier}: ${signature} =\n` +
    `  _makeServerFunction(${descriptor});\n`
  );
}

// Story 9.5 — a query export binds a `_makeQuery` accessor carrying its GET
// descriptor `{ path, kind: "query" }`; `useQuery(<id>, …)` consumes it. The
// signature accepts params only when the query method declares kwargs (FR88).
// Mirrors `Ruact::ServerFunctions::Codegen::V2.render_query_export`.
function renderQueryExportV2(fn) {
  const signature = querySignatureV2(fn);
  const pathLit = JSON.stringify(String(fn.path));
  const descriptor = `{ path: ${pathLit}, kind: "query" }`;
  return (
    `export const ${fn.js_identifier}: ${signature} =\n` +
    `  _makeQuery(${descriptor});\n`
  );
}

// Story 13.4 — picks the query accessor's `params` signature. With structured
// per-kwarg metadata (`fn.params`), build a typed object literal (required +
// optional exact, value type the FR88 wire union); empty params + no rest → the
// bare `()` signature; a `**keyrest` keeps the open `Record<string, unknown>`
// (intersected with any named keys). Falls back to the pre-13.4 `accepts_params`
// boolean when no `params` metadata is present. MUST mirror Ruby `query_signature`.
function querySignatureV2(fn) {
  const params = fn.params;
  if (!Array.isArray(params)) {
    return fn.accepts_params
      ? "(params: Record<string, unknown>) => Promise<unknown>"
      : "() => Promise<unknown>";
  }
  const rest = Boolean(fn.params_rest);
  if (params.length === 0 && !rest) return "() => Promise<unknown>";
  return buildParamsSignatureV2(params, rest);
}

function buildParamsSignatureV2(params, rest) {
  const props = params.map(
    (p) => `${formatParamKey(String(p.name))}${p.required ? "" : "?"}: ${QUERY_PARAM_VALUE_TYPE}`,
  );
  if (props.length === 0) return "(params: Record<string, unknown>) => Promise<unknown>"; // keyrest-only
  let object = `{ ${props.join("; ")} }`;
  if (rest) object += " & Record<string, unknown>";
  return `(params: ${object}) => Promise<unknown>`;
}

// Quote any param key that is not a valid bare TS identifier (so a corrupted
// snapshot cannot break out of the object literal). Mirrors Ruby `format_param_key`.
function formatParamKey(name) {
  return VALID_JS_IDENTIFIER.test(name) ? name : JSON.stringify(name);
}

/**
 * Writes `content` to `outputPath` atomically and only when it differs from
 * the existing file. Returns true if the file was written.
 *
 * @param {string} outputPath
 * @param {string} content
 * @returns {boolean}
 */
export function writeIfChanged(outputPath, content) {
  if (fs.existsSync(outputPath)) {
    const existing = fs.readFileSync(outputPath, "utf8");
    if (existing === content) return false;
  }
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const tag = crypto.createHash("sha256").update(content).digest("hex").slice(0, 8);
  const tmp = `${outputPath}.tmp.${process.pid}.${tag}`;
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, outputPath);
  return true;
}

/**
 * Reads and parses the bridge JSON. Returns null when the file is missing or
 * malformed so the caller can keep the last-known-good output in place. On
 * malformed JSON (vs. simple absence), logs to stderr per AC9 so the developer
 * gets a signal — the silent-swallow case was flagged in Chunk 2 review.
 *
 * @param {string} jsonPath
 * @returns {object|null}
 */
export function readSnapshot(jsonPath) {
  if (!fs.existsSync(jsonPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(jsonPath, "utf8"));
  } catch (err) {
    logError(
      `[ruact] failed to parse server-functions bridge JSON at ${jsonPath}: ` +
        `${err?.message ?? err}. The last-good generated module is left intact — ` +
        "re-run `bin/rails ruact:server_functions:generate` to regenerate the snapshot.",
    );
    return null;
  }
}

/**
 * Resolves the absolute paths the sidecar reads/writes. Both can be overridden
 * via options so the unit tests can drive the codegen against tmpdir fixtures.
 *
 * @param {string} root
 * @param {object} [opts]
 * @returns {{ snapshotJson: string, generatedTs: string }}
 */
export function resolvePaths(root, opts = {}) {
  return {
    snapshotJson:
      opts.snapshotJson || path.resolve(root, "tmp/cache/ruact/server-functions.json"),
    generatedTs:
      opts.generatedTs || path.resolve(root, "app/javascript/.ruact/server-functions.ts"),
  };
}

/**
 * One-shot codegen step: read snapshot → render TS → write-if-changed.
 *
 * @param {string} root
 * @param {object} [opts]
 * @returns {{ wrote: boolean, snapshot: object|null }}
 */
export function generateOnce(root, opts = {}) {
  const { snapshotJson, generatedTs } = resolvePaths(root, opts);
  const snapshot = readSnapshot(snapshotJson);
  if (!snapshot) {
    return { wrote: false, snapshot: null };
  }
  const content = render(snapshot);
  const wrote = writeIfChanged(generatedTs, content);
  return { wrote, snapshot };
}

/**
 * Builds the partial Vite config the sidecar contributes. Sets two
 * `resolve.alias` entries (Story 8.0a AC6 + runtime import path):
 *
 *   - `"@"` → `<root>/app/javascript` (only if the host hasn't set it)
 *   - `"ruact/server-functions-runtime"` → bundled placeholder package
 *
 * Returns an object suitable as a return value from the Vite `config` hook.
 * Vite merges this with the user-supplied config, so existing aliases survive.
 *
 * The `@` alias value is **best effort** here — `config()` runs before Vite
 * has resolved its root, so the only roots we can read are `userConfig.root`
 * (if the user set one) or `process.cwd()`. When the actual `config.root`
 * differs from both (e.g., Vite launched from a sibling directory with the
 * root passed as a CLI flag merged after `config()` returns), the alias is
 * re-canonicalized against `config.root` in `configResolved` (Re-run patch
 * 2026-05-14). The earlier `@PROJECT_APP_JAVASCRIPT@` sentinel approach
 * violated AC6's "config hook returns the AC shape"; the inline-only
 * approach broke when cwd ≠ Vite root. The two-stage approach satisfies both.
 *
 * @param {object} userConfig
 * @returns {object}
 */
export function buildConfigContribution(userConfig) {
  return buildContributionInternal(userConfig).contribution;
}

function buildContributionInternal(userConfig) {
  const bestRoot = path.resolve(userConfig?.root || process.cwd());
  const hostAliases = readUserAliasMap(userConfig);
  const aliases = {};
  let bestEffortAtAlias = null;

  if (hostAliases["@"] === undefined) {
    bestEffortAtAlias = path.resolve(bestRoot, "app/javascript");
    aliases["@"] = bestEffortAtAlias;
    log(
      '[ruact] registered Vite alias "@" → app/javascript ' +
        '(override by setting resolve.alias["@"] in vite.config.js)',
    );
  } else {
    log(
      '[ruact] host vite.config.js defines resolve.alias["@"] — leaving it; ' +
        "ensure it points to app/javascript or the server-functions import will fail",
    );
  }

  aliases[RUNTIME_IMPORT_SPECIFIER] = runtimePackagePath();

  return {
    contribution: { resolve: { alias: aliases } },
    bestEffortAtAlias,
  };
}

// Re-run patch 2026-05-14 — when `config.root` differs from the
// best-effort root we used in `config()`, replace our placeholder with
// the canonical path. Only touches entries that match what WE wrote, so
// host-defined aliases are never overwritten.
function canonicalizeAtAlias(config, bestEffortAtAlias, rootDir) {
  if (bestEffortAtAlias == null) return;
  const canonical = path.resolve(rootDir, "app/javascript");
  if (canonical === bestEffortAtAlias) return;

  const alias = config?.resolve?.alias;
  if (!alias) return;
  if (Array.isArray(alias)) {
    for (const entry of alias) {
      if (entry?.find === "@" && entry.replacement === bestEffortAtAlias) {
        entry.replacement = canonical;
        return;
      }
    }
  } else if (alias["@"] === bestEffortAtAlias) {
    alias["@"] = canonical;
  }
}

function readUserAliasMap(userConfig) {
  const alias = userConfig?.resolve?.alias;
  if (!alias) return {};
  if (Array.isArray(alias)) {
    const map = {};
    for (const entry of alias) {
      if (entry && typeof entry.find === "string") map[entry.find] = entry.replacement;
    }
    return map;
  }
  return alias;
}

/**
 * Installs all server-functions hooks onto an existing Vite plugin object.
 * Wraps the host plugin's `config`, `configResolved`, `buildStart`, and
 * `configureServer` so the existing react-client-manifest behaviour stays
 * intact while the sidecar's behaviour piggybacks.
 *
 * Each wrapper awaits its upstream handler — Vite hooks may legitimately
 * return Promises, and dropping the await would race the sidecar's behaviour
 * with the host plugin's.
 *
 * @param {object} plugin — the host plugin (mutated in place).
 * @param {object} [options]
 * @returns {object} same plugin, fluent return.
 */
export function installServerFunctionsHooks(plugin, options = {}) {
  let rootDir;
  let bestEffortAtAlias = null;

  const originalConfig = plugin.config;
  plugin.config = async function (userConfig, env) {
    const upstream =
      typeof originalConfig === "function"
        ? await originalConfig.call(this, userConfig, env)
        : undefined;
    const { contribution, bestEffortAtAlias: at } = buildContributionInternal(userConfig);
    bestEffortAtAlias = at;
    return mergeConfigs(upstream, contribution);
  };

  const originalConfigResolved = plugin.configResolved;
  plugin.configResolved = async function (config) {
    rootDir = config.root;
    // Re-canonicalize the @ alias against the FINAL Vite root; the value
    // we wrote in config() was best effort (userConfig.root || cwd) which
    // can differ from the actual config.root.
    canonicalizeAtAlias(config, bestEffortAtAlias, rootDir);
    if (typeof originalConfigResolved === "function") {
      return await originalConfigResolved.call(this, config);
    }
    return undefined;
  };

  const originalBuildStart = plugin.buildStart;
  plugin.buildStart = async function (opts) {
    let result;
    if (typeof originalBuildStart === "function") {
      result = await originalBuildStart.call(this, opts);
    }
    generateOnce(rootDir, options);
    return result;
  };

  const originalConfigureServer = plugin.configureServer;
  plugin.configureServer = async function (server) {
    let result;
    if (typeof originalConfigureServer === "function") {
      result = await originalConfigureServer.call(this, server);
    }
    const { snapshotJson, generatedTs } = resolvePaths(rootDir, options);
    const canonicalSnapshots = canonicalPathCandidates(snapshotJson, rootDir);
    server.watcher.add(path.resolve(snapshotJson));
    const onEvent = (file) => {
      // Pass-2 patch 2026-05-14 — chokidar may emit event paths in any of
      // these forms depending on how the watch was registered, the CWD, and
      // whether the watched path crosses a symlink:
      //   • absolute, as-is
      //   • relative to the Vite root (root-relative)
      //   • relative to process.cwd() (cwd-relative)
      //   • the realpath of any of the above (symlink-resolved)
      // Match against the full candidate set on each side so we never miss
      // a legitimate snapshot event because of a path-form mismatch.
      for (const c of canonicalPathCandidates(file, rootDir)) {
        if (canonicalSnapshots.has(c)) {
          generateOnce(rootDir, { ...options, snapshotJson, generatedTs });
          return;
        }
      }
    };
    server.watcher.on("change", onEvent);
    server.watcher.on("add", onEvent);
    return result;
  };

  return plugin;
}

/**
 * Returns the set of absolute path forms that may refer to the same file as
 * `p`, given a Vite `rootDir` for relative-path disambiguation. Includes
 * the path resolved against cwd, resolved against rootDir, and (when the
 * underlying file exists) the realpath of each. Used on both sides of the
 * watcher event comparison to tolerate every chokidar path form.
 */
function canonicalPathCandidates(p, rootDir) {
  const out = new Set();
  const cwdResolved = path.resolve(p);
  const rootResolved = path.resolve(rootDir, p);
  out.add(cwdResolved);
  out.add(rootResolved);
  const r1 = tryRealpath(cwdResolved);
  if (r1) out.add(r1);
  if (rootResolved !== cwdResolved) {
    const r2 = tryRealpath(rootResolved);
    if (r2) out.add(r2);
  }
  return out;
}

function tryRealpath(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return null;
  }
}

function mergeConfigs(a, b) {
  if (!a) return b;
  if (!b) return a;
  return {
    ...a,
    ...b,
    resolve: {
      ...(a.resolve || {}),
      ...(b.resolve || {}),
      alias: mergeAliases((a.resolve || {}).alias, (b.resolve || {}).alias),
    },
  };
}

/**
 * Merges two `resolve.alias` values, preserving array form when either side
 * uses it. Earlier versions object-spread both sides, which corrupted upstream
 * array-form aliases into numeric-keyed objects (`{0: entry, 1: entry, ...}`)
 * — Vite then treated them as nothing and silently dropped the aliases.
 */
function mergeAliases(a, b) {
  if (a == null) return b;
  if (b == null) return a;
  if (Array.isArray(a) || Array.isArray(b)) {
    const toEntries = (alias) => {
      if (Array.isArray(alias)) return [...alias];
      return Object.entries(alias).map(([find, replacement]) => ({ find, replacement }));
    };
    // Vite resolves array-form aliases top-down (first match wins). Our
    // contribution (b) is prepended so it takes precedence — matching the
    // object-merge semantics where `{...a, ...b}` lets b override.
    return [...toEntries(b), ...toEntries(a)];
  }
  return { ...a, ...b };
}

function log(message) {
  if (process.env.RUACT_SILENCE_LOG === "1") return;
  // eslint-disable-next-line no-console
  console.log(message);
}

function logError(message) {
  if (process.env.RUACT_SILENCE_LOG === "1") return;
  // eslint-disable-next-line no-console
  console.error(message);
}
