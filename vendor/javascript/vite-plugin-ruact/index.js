import fs from "node:fs";
import path from "node:path";
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

      // Merge: keep entries that didn't get a hashed URL (dev mode)
      const final = { ...manifest, ...updated };
      // Strip internal _sourceFile field
      for (const entry of Object.values(final)) {
        delete entry._sourceFile;
      }

      writeManifest(path.resolve(root, manifestOutput), final);
    },

    // Dev server: watch components dir and rebuild manifest on change
    configureServer(server) {
      const dir = path.resolve(root, componentsDir);
      server.watcher.add(dir);
      server.watcher.on("change", (file) => {
        if (file.startsWith(dir)) {
          manifest = buildManifest(dir);
          writeManifest(path.resolve(root, manifestOutput), manifest);
        }
      });
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
    const contract = extractContract(content, file);

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
function extractBalanced(str, openIndex, open, close) {
  let depth = 0;
  for (let i = openIndex; i < str.length; i++) {
    const ch = str[i];
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return str.slice(openIndex + 1, i);
    }
  }
  return null;
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
