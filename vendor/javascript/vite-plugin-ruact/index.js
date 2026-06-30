import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installServerFunctionsHooks } from "./server-functions-codegen.mjs";

/**
 * vite-plugin-ruact
 *
 * Scans app/javascript/components for files with "use client" directives and
 * emits public/react-client-manifest.json so the Rails gem can resolve
 * component names to chunk URLs.
 *
 * Manifest format:
 * {
 *   "LikeButton": {
 *     "id":     "/assets/LikeButton-abc123.js",
 *     "name":   "LikeButton",
 *     "chunks": ["/assets/LikeButton-abc123.js"]
 *   }
 * }
 *
 * Story 13.5 (FR100) — compile-time component contract. A component opts into a
 * call-site contract by exporting `__ruactContract` from its own module
 * (HEEx-style `attr`/`slot`, declared next to the component):
 *
 *   export const __ruactContract = {
 *     props: { title: "required", subtitle: "optional" },
 *     slots: { header: "optional" },   // optional; { name: required|optional } or ["name", ...]
 *     passthrough: false,              // optional; true allows undeclared props
 *   };
 *
 * The scanner extracts this NAMES-ONLY (no TS-AST, no value types) into an
 * optional `contract` field on the manifest entry. A component without the
 * export emits no `contract` field (byte-additive, back-compatible). A
 * malformed/partial declaration is warned + skipped (the Ruby side then sees
 * "no contract" and validates nothing — fail open). The Ruby preprocess-time
 * validator (`Ruact::ComponentContract`) reads this and checks `<Component .../>`
 * ERB call sites for missing-required / unknown-prop / slot-misuse before render.
 */
// Story 10.1b — the auto-registry virtual module. The install template (and the
// playgrounds) import this instead of hand-maintaining a `MODULE_REGISTRY`. Its
// value is `{ [manifest id]: moduleExports }`, derived from the SAME scan that
// writes react-client-manifest.json, so registry membership == manifest
// membership and the keys equal the manifest `id` the gem serializes as the
// Flight `moduleId` (client_manifest.rb:79) — by construction, in dev AND prod.
export const REGISTRY_VIRTUAL_ID = "virtual:ruact/registry";
const RESOLVED_REGISTRY_ID = "\0" + REGISTRY_VIRTUAL_ID;

// Story 14.2 (FR104) — the bootstrap virtual module. The React entry that boots
// the app used to be written into every app as `app/javascript/application.jsx`
// (ruact plumbing interleaved with the user's components). It is now served as a
// virtual module from gem-shipped source (`runtime/bootstrap.jsx`), so a fresh
// install leaves `app/javascript/` with ONLY the user's `components/`. The
// generated `vite.config` input is `virtual:ruact/bootstrap`; the gem's
// `ruact_js_assets` view helper targets the same id (dev `<script src>` →
// `/@id/__x00__virtual:ruact/bootstrap`; prod Vite-manifest key
// `virtual:ruact/bootstrap`). Mirrors REGISTRY_VIRTUAL_ID exactly.
export const BOOTSTRAP_VIRTUAL_ID = "virtual:ruact/bootstrap";
const RESOLVED_BOOTSTRAP_ID = "\0" + BOOTSTRAP_VIRTUAL_ID;

// The gem-shipped runtime sources the virtual bootstrap pulls in. Resolved
// against THIS file so the absolute specifiers the bootstrap imports always
// point at the gem copy, regardless of the app's cwd.
const RUNTIME_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "runtime");

export default function ruact(options = {}) {
  const {
    componentsDir = "app/javascript/components",
    manifestOutput = "public/react-client-manifest.json",
  } = options;

  let root;
  let manifest = {};

  return installServerFunctionsHooks({
    name: "vite-plugin-ruact",

    configResolved(config) {
      root = config.root;
    },

    // Story 10.1b / 14.2 — resolve ruact's virtual module ids.
    resolveId(id) {
      if (id === REGISTRY_VIRTUAL_ID) return RESOLVED_REGISTRY_ID;
      if (id === BOOTSTRAP_VIRTUAL_ID) return RESOLVED_BOOTSTRAP_ID;
      return null;
    },

    // Story 10.1b — emit the registry source from the in-memory manifest. The
    // manifest is populated in `buildStart` (and rebuilt by the dev watcher
    // below), which Rollup/Vite run before module loading, so it is ready here
    // in both `build` and `serve`. Keys are the manifest `id` values verbatim
    // (no re-normalization → zero drift with what the gem resolves).
    load(id) {
      if (id === RESOLVED_REGISTRY_ID) return generateRegistrySource(manifest);
      // Story 14.2 — serve the gem-shipped bootstrap source, with its relative
      // runtime imports rewritten to absolute fs specifiers (see below).
      if (id === RESOLVED_BOOTSTRAP_ID) return generateBootstrapSource();
      return null;
    },

    // During dev: build the manifest from source files
    buildStart() {
      manifest = buildManifest(path.resolve(root, componentsDir));
      writeManifest(path.resolve(root, manifestOutput), manifest);
    },

    // During build: update with hashed chunk URLs from the bundle
    generateBundle(_options, bundle) {
      const updated = {};

      for (const [chunkFileName, chunk] of Object.entries(bundle)) {
        if (chunk.type !== "chunk") continue;

        const facadeId = chunk.facadeModuleId;
        if (!facadeId) continue;

        // Find manifest entries whose source file matches this chunk
        for (const [name, entry] of Object.entries(manifest)) {
          if (facadeId === entry._sourceFile) {
            const url = "/" + chunkFileName;
            updated[name] = {
              id: url,
              name,
              chunks: [url],
            };
            // Story 13.5 — preserve the opt-in contract across the dev→build
            // rewrite (the hashed-URL pass must not drop it).
            if (entry.contract) updated[name].contract = entry.contract;
          }
        }
      }

      // Story 10.1b — id-match guard (NFR16 dev/prod parity). The auto-registry
      // (virtual:ruact/registry) is keyed on the source-relative manifest id and
      // is loaded BEFORE this rewrite. If a "use client" component became a
      // standalone facade chunk (e.g. it was added to build.rollupOptions.input,
      // or split via manualChunks), its id is rewritten to a hashed URL here
      // while the registry still resolves it by source path — a SILENT prod
      // hydration miss. Fail the build loudly instead. In the shipped model
      // components are imported by the registry and inlined into the app bundle,
      // so they never become facade chunks and this never fires.
      const rewritten = Object.keys(updated).filter(
        (name) => manifest[name] && updated[name].id !== manifest[name].id
      );
      if (rewritten.length > 0) {
        throw new Error(
          `[vite-plugin-ruact] component(s) ${rewritten.join(", ")} were emitted as ` +
            "standalone (code-split) chunks, so the Flight manifest names them by a " +
            "hashed URL while virtual:ruact/registry resolves them by source path — a " +
            "silent hydration miss in production. Keep \"use client\" components OUT of " +
            "build.rollupOptions.input and avoid manualChunks for them: they are meant " +
            "to be imported by the auto-registry and inlined into the app bundle."
        );
      }

      // Merge: keep entries that didn't get a hashed URL (dev mode)
      const final = { ...manifest, ...updated };
      // Strip internal _sourceFile field
      for (const entry of Object.values(final)) {
        delete entry._sourceFile;
      }

      writeManifest(path.resolve(root, manifestOutput), final);
    },

    // Dev server: watch components dir and rebuild manifest on change. Story
    // 10.1b — also react to add/unlink and invalidate the auto-registry virtual
    // module so a newly added (or removed) "use client" component is registered
    // with ZERO app-code edits (AC1, dev side).
    configureServer(server) {
      const dir = path.resolve(root, componentsDir);
      server.watcher.add(dir);
      const rebuild = (file) => {
        if (!file.startsWith(dir)) return;
        manifest = buildManifest(dir);
        writeManifest(path.resolve(root, manifestOutput), manifest);
        const mod = server.moduleGraph.getModuleById(RESOLVED_REGISTRY_ID);
        if (mod) {
          server.moduleGraph.invalidateModule(mod);
          server.ws.send({ type: "full-reload" });
        }
      };
      server.watcher.on("change", rebuild);
      server.watcher.on("add", rebuild);
      server.watcher.on("unlink", rebuild);
    },
  }, options);
}

export function buildManifest(componentsDir) {
  const manifest = {};

  if (!fs.existsSync(componentsDir)) return manifest;

  const files = walkDir(componentsDir).filter((f) =>
    /\.(jsx?|tsx?)$/.test(f)
  );

  for (const file of files) {
    const content = fs.readFileSync(file, "utf8");
    if (!hasUseClient(content)) continue;

    const exports = extractExportNames(content);
    const relUrl = "/" + path.relative(componentsDir, file);
    let contract = extractContract(content, file);

    // Story 13.5 — a single `__ruactContract` cannot say WHICH component it
    // describes, so it only applies when the file has exactly one component
    // export (the documented one-component-per-file convention). A multi-export
    // file would otherwise validate every export against the same contract —
    // warn + skip rather than guess.
    if (contract && exports.length > 1) {
      // eslint-disable-next-line no-console
      console.warn(
        `[vite-plugin-ruact] ignoring __ruactContract in ${file}: a contract ` +
          `applies to a single component, but this file exports ${exports.length} ` +
          `(${exports.join(", ")}). Split them into one component per file.`
      );
      contract = null;
    }

    for (const name of exports) {
      manifest[name] = {
        id: relUrl,
        name,
        chunks: [relUrl],
        _sourceFile: file, // used during build to match hashed chunks
      };
      // Story 13.5 — opt-in, byte-additive: only present when declared.
      if (contract) manifest[name].contract = contract;
    }
  }

  return manifest;
}

// Story 10.1b (AC1, AC2) — render the auto-registry virtual module source from a
// manifest (the same object `buildManifest` produces). The result is an ESM
// module whose default export is `{ [manifest id]: moduleNamespace }`:
//
//   import * as __ruact_m0 from "/abs/app/javascript/components/PostList.jsx";
//   const MODULE_REGISTRY = { "/PostList.jsx": __ruact_m0 };
//   export default MODULE_REGISTRY;
//
// Why keyed on the manifest `id` (not a re-derived path): the gem serializes
// `entry["id"]` as the Flight `moduleId`, and the client resolves
// `moduleRegistry[row.moduleId]` — so keying the registry on the very same
// `id` makes the id-match invariant hold BY CONSTRUCTION. The shipped runtime
// loads components from this eager registry (the Flight client ignores the
// Import row's `chunks`), so each component is statically imported and inlined
// into the app bundle; it never becomes a standalone facade chunk, and
// `generateBundle`'s hashed-URL rewrite (which only fires for facade chunks)
// leaves the component `id` as its source-relative path in prod exactly as in
// dev. NFR16 dev/prod parity therefore holds with one source-relative key set.
//
// One import per source file (a file may export several components sharing an
// `id`/`_sourceFile`); membership equals manifest membership because we iterate
// the manifest the scan built ("use client"-only, `.jsx`/`.tsx`, same dir).
export function generateRegistrySource(manifest) {
  const byId = new Map(); // manifest id -> absolute source file
  for (const entry of Object.values(manifest || {})) {
    if (!entry || !entry._sourceFile || !entry.id) continue;
    if (!byId.has(entry.id)) byId.set(entry.id, entry._sourceFile);
  }

  const lines = [
    "// AUTO-GENERATED by vite-plugin-ruact — component auto-registry (Story 10.1b).",
    "// Maps each react-client-manifest `id` to its module exports. Do not edit.",
  ];
  const props = [];
  let i = 0;
  for (const [id, sourceFile] of byId) {
    const local = `__ruact_m${i++}`;
    lines.push(`import * as ${local} from ${JSON.stringify(toImportSpecifier(sourceFile))};`);
    props.push(`  ${JSON.stringify(id)}: ${local},`);
  }
  lines.push("const MODULE_REGISTRY = {", ...props, "};", "export default MODULE_REGISTRY;", "");

  return lines.join("\n");
}

// Story 14.2 (FR104) — render the virtual bootstrap source from the gem-shipped
// `runtime/bootstrap.jsx`. A `load` hook returns module TEXT whose relative
// imports resolve against the resolved id (`\0virtual:ruact/bootstrap`), which
// is NOT a filesystem path — so `./flight-client.js` / `./ruact-router.js`
// would fail. We rewrite those two specifiers to ABSOLUTE fs specifiers into the
// gem `runtime/` dir (the same technique `generateRegistrySource` uses via
// `toImportSpecifier`). The bare `react` / `react-dom/client` specifiers and the
// `virtual:ruact/registry` id are left untouched — Vite resolves them from the
// app root (so React comes from the USER's node_modules: one React instance).
export function generateBootstrapSource(runtimeDir = RUNTIME_DIR) {
  const src = fs.readFileSync(path.join(runtimeDir, "bootstrap.jsx"), "utf8");
  const abs = (name) => toImportSpecifier(path.join(runtimeDir, name));
  // Rewrite EVERY `from './<runtime>.js'` import specifier to its absolute fs
  // path. Matching the quoted `from '...'` form (not the bare filename) avoids
  // hitting prose mentions of the file in comments, and the global regex
  // tolerates either quote style. The replacement is supplied as a function so a
  // `$` in the absolute path is never treated as a replacement pattern.
  const rewrite = (code, name) => {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return code.replace(
      new RegExp(`from\\s+(['"])\\./${escaped}\\1`, "g"),
      () => `from '${abs(name)}'`,
    );
  };
  return rewrite(rewrite(src, "flight-client.js"), "ruact-router.js");
}

// A bundler import specifier for an absolute fs path. Vite/Rollup resolve
// absolute paths directly; normalize Windows backslashes to forward slashes so
// the emitted specifier is a valid module string on every platform.
function toImportSpecifier(absPath) {
  return absPath.replace(/\\/g, "/");
}

function hasUseClient(content) {
  // "use client" must appear as a directive at the top of the file
  return /^\s*["']use client["']/m.test(content);
}

function extractExportNames(content) {
  const names = new Set();

  // export function Foo
  // export const Foo
  // export class Foo
  const namedRe = /export\s+(?:default\s+)?(?:function|const|class|let|var)\s+([A-Z][A-Za-z0-9]*)/g;
  let m;
  while ((m = namedRe.exec(content)) !== null) {
    names.add(m[1]);
  }

  // export { Foo, Bar }
  const bracedRe = /export\s+\{([^}]+)\}/g;
  while ((m = bracedRe.exec(content)) !== null) {
    for (const part of m[1].split(",")) {
      const name = part.trim().split(/\s+as\s+/).pop().trim();
      if (/^[A-Z]/.test(name)) names.add(name);
    }
  }

  return Array.from(names);
}

// Story 13.5 (FR100) — extract the opt-in `__ruactContract` declaration.
//
// NAMES-ONLY by design (no TS-AST, no value types): the Ruby preprocess-time
// validator only needs prop/slot names + required/optional. We locate the
// exported object literal, balance its braces, then pull names out of the
// `props` / `slots` sub-blocks with targeted regexes (robust to formatting,
// and immune to eval). Returns:
//   - null  when the component declares no contract (byte-additive opt-out)
//   - null  when the declaration is malformed/empty (warn + skip → Ruby fails open)
//   - { props?, slots?, passthrough? } otherwise (only non-empty members present)
export function extractContract(content, file) {
  const marker = /export\s+(?:default\s+)?(?:const|let|var)\s+__ruactContract\s*=\s*/m;
  const m = marker.exec(content);
  if (!m) return null;

  const braceStart = content.indexOf("{", m.index + m[0].length);
  if (braceStart === -1) return warnSkip(file);

  const objText = extractBalanced(content, braceStart, "{", "}");
  if (objText === null) return warnSkip(file);

  const contract = {};

  const props = extractRequiredness(extractBlock(objText, "props", "{", "}"));
  if (props && Object.keys(props).length) contract.props = props;

  const slots = extractRequiredness(extractBlock(objText, "slots", "{", "}"));
  if (slots && Object.keys(slots).length) {
    contract.slots = slots;
  } else {
    // Array form: slots: ["header", "footer"] → all optional.
    const arr = extractBlock(objText, "slots", "[", "]");
    if (arr !== null) {
      const names = {};
      const nameRe = /["'`]([^"'`]+)["'`]/g;
      let s;
      while ((s = nameRe.exec(arr)) !== null) names[s[1]] = "optional";
      if (Object.keys(names).length) contract.slots = names;
    }
  }

  if (/\bpassthrough\s*:\s*true\b/.test(objText)) contract.passthrough = true;

  // A contract with no props, no slots, and no passthrough carries no
  // information — treat as malformed/empty and fail open.
  if (!contract.props && !contract.slots && !contract.passthrough) {
    return warnSkip(file);
  }

  return contract;
}

// Parse a `{ name: "required", other: "optional" }` block into a
// { name: "required" | "optional" } map. Accepts quoted or bare values, and an
// object form `name: { required: true }`. Returns {} for an empty block.
function extractRequiredness(block) {
  if (block === null) return null;
  const map = {};
  // name: "required" | 'optional' | required  (string or bare identifier)
  const strRe = /([A-Za-z_$][\w$]*)\s*:\s*["'`]?(required|optional)["'`]?/g;
  let m;
  while ((m = strRe.exec(block)) !== null) map[m[1]] = m[2];
  // name: { required: true }  → required; { required: false } → optional
  const objRe = /([A-Za-z_$][\w$]*)\s*:\s*\{[^}]*?\brequired\s*:\s*(true|false)[^}]*?\}/g;
  while ((m = objRe.exec(block)) !== null) {
    map[m[1]] = m[2] === "true" ? "required" : "optional";
  }
  return map;
}

// Extract the balanced inner text of `key: <open> ... <close>` from `objText`.
// Returns the inner text (without the delimiters) or null when the key is
// absent or the delimiters are unbalanced.
function extractBlock(objText, key, open, close) {
  const keyRe = new RegExp(`\\b${key}\\s*:\\s*\\${open}`, "m");
  const km = keyRe.exec(objText);
  if (!km) return null;
  const start = km.index + km[0].length - 1; // position of `open`
  const inner = extractBalanced(objText, start, open, close);
  return inner;
}

// Given a string and the index of an opening delimiter, return the inner text
// up to (excluding) the matching close delimiter, or null when unbalanced.
// String literals ('...', "...", `...`) and comments (// and / * ... * /) are
// skipped so a brace inside a comment or string never throws off the balance.
function extractBalanced(str, openIndex, open, close) {
  let depth = 0;
  let i = openIndex;
  while (i < str.length) {
    const ch = str[i];
    const next = str[i + 1];

    if (ch === "/" && next === "/") {
      const nl = str.indexOf("\n", i);
      if (nl === -1) return null;
      i = nl + 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      const end = str.indexOf("*/", i + 2);
      if (end === -1) return null;
      i = end + 2;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      i = skipString(str, i);
      if (i === -1) return null;
      continue;
    }

    if (ch === open) {
      depth++;
    } else if (ch === close) {
      depth--;
      if (depth === 0) return str.slice(openIndex + 1, i);
    }
    i++;
  }
  return null;
}

// Skip a JS string/template literal starting at the opening quote at +i+.
// Returns the index just past the closing quote, or -1 if unterminated.
function skipString(str, i) {
  const quote = str[i];
  i++;
  while (i < str.length) {
    const ch = str[i];
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === quote) return i + 1;
    i++;
  }
  return -1;
}

function warnSkip(file) {
  // eslint-disable-next-line no-console
  console.warn(
    `[vite-plugin-ruact] ignoring malformed __ruactContract in ${file} ` +
      `(could not extract prop/slot names — the component will not be contract-validated)`
  );
  return null;
}

function writeManifest(outputPath, manifest) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(manifest, null, 2));
}

function walkDir(dir) {
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...walkDir(full));
    } else {
      results.push(full);
    }
  }
  return results;
}
