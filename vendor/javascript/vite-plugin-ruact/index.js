import fs from "node:fs";
import path from "node:path";

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
 */
export default function ruact(options = {}) {
  const {
    componentsDir = "app/javascript/components",
    manifestOutput = "public/react-client-manifest.json",
  } = options;

  let root;
  let manifest = {};

  return {
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
  };
}

function buildManifest(componentsDir) {
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

    for (const name of exports) {
      manifest[name] = {
        id: relUrl,
        name,
        chunks: [relUrl],
        _sourceFile: file, // used during build to match hashed chunks
      };
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
