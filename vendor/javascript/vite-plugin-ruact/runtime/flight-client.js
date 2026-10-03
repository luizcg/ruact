/**
 * Minimal React Flight wire format parser.
 *
 * Handles the subset we emit from the Ruby server:
 *   - Model rows:  <hex_id>:<json>\n
 *   - Import rows: <hex_id>:I[moduleId, exportName, chunks]\n
 *   - Error rows:  <hex_id>:E<json>\n
 *   - Text rows:   <hex_id>:T<hex_byte_length>,<utf-8 text>   (NO newline)
 *
 * Every string of 1024 bytes or more travels as a text row, framed by its
 * byte length, and is referenced from a model row as "$T<hex_id>". Both the
 * initial load and the router read rows through ONE incremental byte parser
 * ({@link createRowParser}), so a payload decodes the same whichever way it
 * arrives and wherever the network splits it.
 *
 * Returns a React element tree by recursively converting
 * ["$", type, key, props] tuples into React.createElement calls.
 *
 * Supports Suspense streaming:
 *   - "$SS" element type → React.Suspense
 *   - "$L{hex}" referencing a missing row → React.lazy() that resolves when the row arrives
 */

import { createElement, Fragment, lazy, Suspense } from "react";

// ---------------------------------------------------------------------------
// Pending chunk registry — used for streaming Suspense deferred rows
// ---------------------------------------------------------------------------

const pendingChunks = new Map(); // rowId → { promise, resolve }
const lazyCache     = new Map(); // rowId → React.lazy component (memoized)

/** Clear all pending lazy refs. Call at the start of each navigation. */
export function clearPendingChunks() {
  pendingChunks.clear();
  lazyCache.clear();
}

/**
 * Called when a deferred model row arrives during streaming.
 * Resolves the pending lazy component so React re-renders the Suspense boundary.
 *
 * @param {number} rowId
 * @param {*}      element - the React element tree built from the deferred row
 */
export function resolvePendingChunk(rowId, element) {
  const chunk = pendingChunks.get(rowId);
  if (chunk) {
    chunk.resolve(element);
    pendingChunks.delete(rowId);
  }
}

function createLazyForPending(rowId) {
  if (lazyCache.has(rowId)) return lazyCache.get(rowId);

  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  pendingChunks.set(rowId, { promise, resolve });

  // React.lazy expects { default: ComponentType }. We wrap the element in a function component.
  const LazyComp = lazy(() => promise.then((el) => ({ default: () => el })));
  lazyCache.set(rowId, LazyComp);
  return LazyComp;
}

// ---------------------------------------------------------------------------
// Row parsing
// ---------------------------------------------------------------------------

/**
 * Parse a single Flight wire format line into { id, row }.
 * Returns null for blank or malformed lines.
 *
 * @param {string} line
 * @returns {{ id: number, row: object } | null}
 */
export function parseLine(line) {
  if (!line.trim()) return null;

  const colonIdx = line.indexOf(":");
  if (colonIdx === -1) return null;
  if (colonIdx === 0) return null; // hint row (":H…") — a preload signal, no id

  const id   = parseInt(line.slice(0, colonIdx), 16);
  const rest = line.slice(colonIdx + 1);

  try {
    if (rest.startsWith("I")) {
      const [moduleId, exportName] = JSON.parse(rest.slice(1));
      return { id, row: { kind: "import", moduleId, exportName } };
    }

    if (rest.startsWith("E")) {
      const errorData = JSON.parse(rest.slice(1));
      const message = typeof errorData === "string"
        ? errorData
        : (errorData.message || String(errorData));
      return { id, row: { kind: "error", message } };
    }

    return { id, row: { kind: "model", value: JSON.parse(rest) } };
  } catch (e) {
    console.warn("[flight-client] Skipping malformed row:", line, e);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Incremental row parser (bytes in, rows out)
// ---------------------------------------------------------------------------

const COLON   = 0x3a;
const COMMA   = 0x2c;
const NEWLINE = 0x0a;
const TAG_T   = 0x54;
const HEX     = /^[0-9a-fA-F]+$/;

const utf8 = new TextDecoder("utf-8");

/**
 * An incremental Flight row parser. Feed it the payload's bytes in any number
 * of chunks — split anywhere, including inside a header, a length or a UTF-8
 * code point — and it calls `onRow({ id, row })` once per complete row.
 *
 * Text rows are framed by their BYTE length, so the parser works on bytes,
 * never on decoded strings: a string's `length` counts UTF-16 units and would
 * misread any non-ASCII text.
 *
 * `end()` must be called when the input is complete. A truncated text row or
 * a malformed length throws instead of yielding a partial payload.
 *
 * @param {(parsed: { id: number, row: object }) => void} onRow
 * @returns {{ push(bytes: Uint8Array): void, end(): void }}
 */
export function createRowParser(onRow) {
  let buf = new Uint8Array(0);
  let pos = 0;

  const append = (bytes) => {
    const rest = buf.length - pos;
    const next = new Uint8Array(rest + bytes.length);
    next.set(buf.subarray(pos), 0);
    next.set(bytes, rest);
    buf = next;
    pos = 0;
  };

  const emitLine = (start, end) => {
    const parsed = parseLine(utf8.decode(buf.subarray(start, end)));
    if (parsed) onRow(parsed);
  };

  // Parses one row starting at `pos`. Returns false when it needs more bytes.
  const step = () => {
    const colon = buf.indexOf(COLON, pos);
    if (colon === -1) return false;

    const header = utf8.decode(buf.subarray(pos, colon));
    if (colon + 1 >= buf.length) return false;

    if (HEX.test(header.trim()) && buf[colon + 1] === TAG_T) {
      const comma = buf.indexOf(COMMA, colon + 2);
      if (comma === -1) return false;
      const lengthHex = utf8.decode(buf.subarray(colon + 2, comma));
      if (!HEX.test(lengthHex)) {
        throw new Error(`[flight-client] Malformed text row length "${lengthHex}" for row ${header.trim()}`);
      }
      const length = parseInt(lengthHex, 16);
      const start  = comma + 1;
      if (start + length > buf.length) return false;
      const id = parseInt(header.trim(), 16);
      onRow({ id, row: { kind: "text", value: utf8.decode(buf.subarray(start, start + length)) } });
      pos = start + length;
      return true;
    }

    const newline = buf.indexOf(NEWLINE, colon + 1);
    if (newline === -1) return false;
    emitLine(pos, newline);
    pos = newline + 1;
    return true;
  };

  return {
    push(bytes) {
      append(bytes);
      // Blank separators between rows carry nothing.
      while (pos < buf.length) {
        while (pos < buf.length && (buf[pos] === NEWLINE || buf[pos] === 0x0d)) pos++;
        if (pos >= buf.length || !step()) break;
      }
    },

    end() {
      const rest = utf8.decode(buf.subarray(pos));
      if (!rest.trim()) return;
      // A last model/import/error row without its trailing newline is complete
      // as far as JSON can tell; a cut-off text row or header is not.
      const colon = rest.indexOf(":");
      const header = colon === -1 ? "" : rest.slice(0, colon).trim();
      if (colon !== -1 && HEX.test(header) && rest[colon + 1] === "T") {
        throw new Error(`[flight-client] Truncated Flight payload: text row ${header} is incomplete`);
      }
      if (colon === -1) {
        throw new Error(`[flight-client] Truncated Flight payload: "${rest.slice(0, 40)}"`);
      }
      const parsed = parseLine(rest);
      if (!parsed) throw new Error(`[flight-client] Truncated Flight payload: "${rest.slice(0, 40)}"`);
      onRow(parsed);
      pos = buf.length;
    },
  };
}

// ---------------------------------------------------------------------------
// Tree building
// ---------------------------------------------------------------------------

/**
 * Build a React element tree from a fully-populated rows Map.
 *
 * @param {Map}    rows           - id → { kind, ... } rows
 * @param {Object} moduleRegistry - { [moduleId]: { [exportName]: Component } }
 * @returns React element tree
 */
export function buildTreeFromRows(rows, moduleRegistry) {
  const root = rows.get(0);
  if (!root) throw new Error("[flight-client] No root row (id=0) found in payload");
  if (root.kind === "error") throw new Error(`[ruact] Server error: ${root.message}`);
  if (root.kind !== "model") throw new Error("[flight-client] Root row is not a model row");
  return buildTree(root.value, rows, moduleRegistry);
}

/**
 * Build a React element tree from a single row value.
 * Used when resolving a deferred (Suspense) row that has arrived via streaming.
 *
 * @param {*}      value
 * @param {Map}    rows
 * @param {Object} moduleRegistry
 */
export function buildTree(value, rows, moduleRegistry) {
  return _buildTree(value, rows, moduleRegistry);
}

/**
 * Parse a Flight payload string and return a React element tree.
 * Convenience wrapper — used for the initial (non-streaming) page load.
 *
 * @param {string}  payload
 * @param {Object}  moduleRegistry
 */
export function createFromFlightPayload(payload, moduleRegistry) {
  const rows   = new Map();
  const parser = createRowParser(({ id, row }) => rows.set(id, row));
  parser.push(new TextEncoder().encode(payload));
  parser.end();
  return buildTreeFromRows(rows, moduleRegistry);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function _buildTree(value, rows, moduleRegistry) {
  if (value === null || value === undefined) return value;

  // --- Strings with special $ prefixes ---
  if (typeof value === "string") {
    if (value.startsWith("$$"))   return value.slice(1);   // escaped $
    if (value === "$undefined")   return undefined;
    if (value === "$NaN")         return NaN;
    if (value === "$Infinity")    return Infinity;
    if (value === "$-Infinity")   return -Infinity;
    if (value === "$-0")          return -0;
    if (value.startsWith("$T")) {
      const refId = parseInt(value.slice(2), 16);
      const row   = rows.get(refId);
      if (!row || row.kind !== "text") {
        throw new Error(`[flight-client] Text row ${value.slice(2)} is referenced but was never received`);
      }
      return row.value;
    }
    if (value.startsWith("$L")) {
      const refId = parseInt(value.slice(2), 16);
      const row   = rows.get(refId);

      if (!row) {
        // Row hasn't arrived yet — create a lazy component that suspends until it does
        return createLazyForPending(refId);
      }
      if (row.kind === "error") {
        throw new Error(`[ruact] Server error: ${row.message}`);
      }
      if (row.kind === "import") {
        const mod = moduleRegistry[row.moduleId];
        if (!mod) throw new Error(`[flight-client] Module not registered: ${row.moduleId}`);
        const component = mod[row.exportName];
        if (!component) throw new Error(`[flight-client] Export "${row.exportName}" not found in ${row.moduleId}`);
        return component;
      }
      // Model row — deferred content already arrived (non-streaming path).
      // Wrap in a function component so it can be used as a type in createElement.
      const content = _buildTree(row.value, rows, moduleRegistry);
      return () => content;
    }
    return value;
  }

  // --- Arrays ---
  if (Array.isArray(value)) {
    // React element tuple: ["$", type, key, props]
    if (value[0] === "$") {
      const [, rawType, key, rawProps] = value;
      const type   = resolveType(rawType, rows, moduleRegistry);
      const props  = buildProps(rawProps, rows, moduleRegistry);
      if (key != null) props.key = key;
      return createElement(type, props);
    }

    // Plain array — fragment children OR a data array sitting in a prop.
    //
    // Arity is preserved. This walker has no positional information: it cannot
    // tell a `children` array from a list prop, so any shape change made here
    // is made to both. It used to collapse single-element arrays (`items[0]`
    // when `length === 1`), which silently turned a one-row list prop into the
    // row itself — issue #62.
    //
    // Nothing needs to compensate: the server already collapses a lone child
    // before it reaches the wire (`html_converter.rb:188`, and the Suspense
    // path at `:202`), and React renders an array of children fine. If a
    // client-side collapse is ever needed, it belongs in `buildProps` under
    // `key === "children"`, where the position IS known.
    return value.map((v) => _buildTree(v, rows, moduleRegistry));
  }

  // --- Plain objects ---
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, _buildTree(v, rows, moduleRegistry)])
    );
  }

  return value;
}

function resolveType(rawType, rows, moduleRegistry) {
  if (typeof rawType === "string") {
    if (rawType === "$SS")        return Suspense;                                    // React.Suspense
    if (rawType.startsWith("$L")) return _buildTree(rawType, rows, moduleRegistry);  // lazy / import
    return rawType;
  }
  return rawType;
}

function buildProps(rawProps, rows, moduleRegistry) {
  if (!rawProps) return {};
  const props = {};
  for (const [key, val] of Object.entries(rawProps)) {
    if (key === "children") {
      const children = _buildTree(val, rows, moduleRegistry);
      if (children !== undefined) props.children = children;
    } else {
      props[key] = _buildTree(val, rows, moduleRegistry);
    }
  }
  return props;
}
