/**
 * Minimal React Flight wire format parser.
 *
 * Handles the subset we emit from the Ruby server:
 *   - Model rows:  <hex_id>:<json>\n
 *   - Import rows: <hex_id>:I[moduleId, exportName, chunks]\n
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
  const rows = new Map();
  for (const line of payload.split("\n")) {
    const parsed = parseLine(line);
    if (parsed) rows.set(parsed.id, parsed.row);
  }
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

    // Plain array / fragment children
    const items = value.map((v) => _buildTree(v, rows, moduleRegistry));
    return items.length === 1 ? items[0] : items;
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
