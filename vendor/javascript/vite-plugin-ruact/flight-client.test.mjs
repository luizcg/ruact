// Story 17.0a (issue #62) — the Flight client must not collapse arrays.
//
// `flight-client.js` was the only runtime module in this package without a unit
// test, and the defect this file pins is what that gap allowed: `_buildTree`
// applied a single-element unwrap (`items.length === 1 ? items[0] : items`) to
// EVERY array it walked. `_buildTree` is a generic value walker with no
// positional information, so it could not tell a `children` array from a data
// array sitting in a prop — a list prop holding exactly one row arrived at the
// client component as the row itself.
//
// What this file covers:
//
//   1. Data props — 0 / 1 / 2 elements, at top level and nested, arrive with
//      their arity intact. The n=1 cases are the regression; n=0 and n=2 are
//      guards that the fix does not over-correct in the other direction.
//   2. Children — 0 / 1 / 2, asserting the REBUILT content (type, key, nested
//      children), not just arity, so a rebuild returning nulls cannot pass.
//      Children keep their arity too: the server collapses a lone TAG-NESTED
//      child before the wire (`html_converter.rb:188`, Suspense at `:202`), but
//      an explicit `children={[...]}` prop reaches the client as an array and
//      now stays one. See the contract note on that describe block.
//   3. The gem-produced fixture — the same assertion driven by wire bytes the
//      Ruby serializer wrote, not by a literal typed here.
//
// Isolation: `flight-client.js` keeps `pendingChunks` and `lazyCache` as
// module-level Maps that survive between tests in one process. `lazyCache` is
// memoized by rowId, so two cases reusing an id would leak into each other.
// `clearPendingChunks()` in `beforeEach` is what keeps this file order-
// independent. Vitest is not configured to shuffle, so nothing here depends on
// that guard today — it is insurance against a case that reuses a row id, and
// against shuffling being turned on later.

import { describe, it, expect, beforeEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import {
  buildTree,
  createFromFlightPayload,
  createRowParser,
  clearPendingChunks,
} from "./runtime/flight-client.js";

// A stand-in client component. Never rendered — these tests assert the props
// the client BUILDS, which is the contract the component then consumes.
const TaskList = () => null;
const PostList = () => null; // the fixture's component — see the last describe
const MODULE_REGISTRY = {
  "/TaskList.jsx": { TaskList },
  "/PostList.jsx": { PostList },
};

const EMPTY_ROWS = new Map();

/** Wire payload: one import row + a root element carrying `props`. */
function payloadWithProps(props) {
  return [
    '1:I["/TaskList.jsx","TaskList"]',
    `0:["$","$L1",null,${JSON.stringify(props)}]`,
    "",
  ].join("\n");
}

beforeEach(() => {
  clearPendingChunks();
});

describe("Story 17.0a — data props keep their arity", () => {
  it("a prop holding ONE item arrives as a one-element array", () => {
    const tree = createFromFlightPayload(
      payloadWithProps({ tasks: [{ id: 6, title: "Buy coffee" }] }),
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.tasks)).toBe(true);
    expect(tree.props.tasks).toEqual([{ id: 6, title: "Buy coffee" }]);
  });

  it("a prop holding TWO items is unchanged", () => {
    const tree = createFromFlightPayload(
      payloadWithProps({ tasks: [{ id: 6 }, { id: 7 }] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.tasks).toEqual([{ id: 6 }, { id: 7 }]);
  });

  it("a prop holding an EMPTY array stays an empty array", () => {
    const tree = createFromFlightPayload(
      payloadWithProps({ tasks: [] }),
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.tasks)).toBe(true);
    expect(tree.props.tasks).toEqual([]);
  });

  it("a one-element array NESTED inside an object prop keeps its arity", () => {
    const tree = createFromFlightPayload(
      payloadWithProps({ page: { rows: [{ id: 6 }], total: 1 } }),
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.page.rows)).toBe(true);
    expect(tree.props.page.rows).toEqual([{ id: 6 }]);
  });

  it("a one-element array of PRIMITIVES keeps its arity", () => {
    const tree = createFromFlightPayload(
      payloadWithProps({ tags: ["$$ruby"] }),
      MODULE_REGISTRY,
    );

    // Decoded, not merely carried: "$$ruby" on the wire is "$ruby" in the prop.
    expect(tree.props.tags).toEqual(["$ruby"]);
  });

  it("the scaffold's own prop shape survives (issue #62 reproduction)", () => {
    // `<PostList posts={rows} />` with exactly one record. The generated
    // scaffold gates its table on `sortedRows.length > 0`, so an object here
    // renders neither the table nor the empty state — a blank list, no error.
    // The throw needs a specific sequence, because the sort controls live
    // inside the table that did not render: search (which works, since results
    // arrive as JSON), sort, then clear the search — that puts the object back
    // through `[...rows]`.
    const tree = createFromFlightPayload(
      payloadWithProps({ posts: [{ id: 1, title: "First post" }] }),
      MODULE_REGISTRY,
    );

    // The component itself, not just its props — a rebuild that resolved the
    // `$L` reference to a plain "div" would keep every prop assertion green
    // while never running PostList at all.
    expect(tree.type).toBe(TaskList);

    const { posts } = tree.props;
    expect(Array.isArray(posts)).toBe(true);
    expect(posts).toHaveLength(1);
    expect(() => [...posts]).not.toThrow();
  });

  it("an array INSIDE an array keeps both dimensions", () => {
    // `.flat()` in the walker would collapse this and still satisfy every
    // one-dimensional assertion above.
    const tree = createFromFlightPayload(
      payloadWithProps({ grid: [[1, 2], [3]] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.grid).toEqual([[1, 2], [3]]);
  });

  it("a ONE-element outer array wrapping an array keeps both levels", () => {
    // Distinct from the grid case above, whose outer array has two members: a
    // collapse conditioned on `length === 1 && Array.isArray(items[0])` would
    // pass that one and corrupt this one.
    const tree = createFromFlightPayload(
      payloadWithProps({ matrix: [[1, 2]] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.matrix).toEqual([[1, 2]]);
  });

  it("an `undefined` MEMBER is kept — Flight distinguishes it from absence", () => {
    // `$undefined` is a wire sentinel (project-context §7), so `[undefined]` is
    // a one-member array, not an empty one. A `.filter(v => v !== undefined)`
    // in the walker would silently make it empty.
    const tree = createFromFlightPayload(
      payloadWithProps({ slots: ["$undefined"] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.slots).toHaveLength(1);
    expect(tree.props.slots[0]).toBeUndefined();
  });

  it("falsy items survive — they are values, not absences", () => {
    // `.filter(Boolean)` in the walker would drop these and still satisfy
    // every length assertion that uses truthy items.
    const tree = createFromFlightPayload(
      payloadWithProps({ flags: [false, 0, null, "", 1] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.flags).toEqual([false, 0, null, "", 1]);
  });
});

describe("Story 17.0a — children keep their arity too (contract, decided 2026-09-09)", () => {
  // Decision: arity is preserved for `children` as well as for data props.
  //
  // The server collapses a lone child produced by TAG NESTING before the wire
  // (`html_converter.rb:188`, Suspense at `:202`), so that path is unaffected.
  // But `children` passed as an EXPLICIT PROP on a self-closing tag —
  // `<Label children={["hi"]} />` — reaches the wire as an array, and Story
  // 15.2's loud error does not cover it (`erb_preprocessor.rb:174` exempts
  // self-closing tags). Before this story the client collapsed that to `"hi"`.
  // It no longer does: you passed an array, you get an array.
  //
  // Taken deliberately while the library has no external adopters — the only
  // moment where making the contract consistent costs nothing.

  it("a single child NESTED IN A TAG arrives collapsed, because the server collapsed it", () => {
    const tree = buildTree(
      ["$", "div", null, { children: ["$", "em", null, { children: "hi" }] }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    // Not an array: the server sent the element itself, and it rebuilds as one.
    expect(Array.isArray(tree.props.children)).toBe(false);
    expect(tree.props.children.type).toBe("em");
    expect(tree.props.children.props.children).toBe("hi");
  });

  it("a single TEXT child nested in a tag arrives as the string", () => {
    const tree = buildTree(
      ["$", "div", null, { children: "hi" }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(tree.props.children).toBe("hi");
  });

  it("multiple children arrive as an array, each one rebuilt", () => {
    const tree = buildTree(
      ["$", "ul", null, {
        children: [
          ["$", "li", "a", { children: "one" }],
          ["$", "li", "b", { children: "two" }],
        ],
      }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    const kids = tree.props.children;
    expect(Array.isArray(kids)).toBe(true);
    expect(kids).toHaveLength(2);
    // Content, not just arity — a rebuild that returned nulls would pass a
    // length check and fail this one.
    expect(kids.map((k) => k.type)).toEqual(["li", "li"]);
    expect(kids.map((k) => k.key)).toEqual(["a", "b"]);
    expect(kids.map((k) => k.props.children)).toEqual(["one", "two"]);
  });

  it("an EXPLICIT one-element children prop stays a one-element array", () => {
    // The contract change. `<Label children={["hi"]} />` — verified against the
    // Ruby pipeline to reach the wire as `{"children":["hi"]}`.
    const tree = buildTree(
      ["$", "span", null, { children: ["hi"] }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(tree.props.children).toEqual(["hi"]);
  });

  it("a one-element children array of ELEMENTS stays an array, rebuilt", () => {
    const tree = buildTree(
      ["$", "ul", null, { children: [["$", "li", "only", { children: "just one" }]] }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    const kids = tree.props.children;
    expect(Array.isArray(kids)).toBe(true);
    expect(kids).toHaveLength(1);
    expect(kids[0].type).toBe("li");
    expect(kids[0].key).toBe("only");
    expect(kids[0].props.children).toBe("just one");
  });

  it("an EMPTY children array stays an empty array", () => {
    // AC3's n=0 for children. Distinct from "no children prop at all" below:
    // this one is present and empty, and must not become visible content.
    const tree = buildTree(
      ["$", "ul", null, { children: [] }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.children)).toBe(true);
    expect(tree.props.children).toHaveLength(0);
  });

  it("an element with no children prop has none after rebuilding", () => {
    const tree = buildTree(["$", "br", null, {}], EMPTY_ROWS, MODULE_REGISTRY);

    expect("children" in tree.props).toBe(false);
  });
});

describe("Story 17.0a — the contract, driven by a gem-produced fixture", () => {
  // The bytes were written by the Ruby serializer, not typed here.
  //
  // The two sides guarantee DIFFERENT things, and neither reddens for the
  // other: `spec/ruact/flight/serializer_spec.rb` ("single-element array prop
  // survives the wire (Story 17.0a)") asserts that what the serializer emits
  // still equals this file, so a server-side change reddens THERE; this test
  // asserts that these bytes rebuild into a one-element array, so a client-side
  // change reddens HERE. What the pair buys is that the client is exercised
  // against real server output rather than a literal someone typed — the
  // Story 5.2 pattern. It does not buy simultaneous failure.
  const FIXTURE = path.join(
    import.meta.dirname,
    "../../../spec/fixtures/flight/single_element_array_prop.txt",
  );

  it("the fixture the gem wrote rebuilds as a one-element array", () => {
    const payload = fs.readFileSync(FIXTURE, "utf8");
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);

    expect(tree.type).toBe(PostList);
    expect(Array.isArray(tree.props.posts)).toBe(true);
    // The title is "$$5 plan" ON THE WIRE (§7 prepends one "$"). Asserting the
    // DECODED value means a walker that preserved arity but stopped rebuilding
    // scalar members would fail here rather than pass.
    expect(tree.props.posts).toEqual([{ id: 1, title: "$5 plan" }]);
  });
});

// Story 17-0d — every string of 1024+ bytes travels as a `T` row framed by its
// BYTE length, with no trailing newline. The decoder split on "\n" and so lost
// the root row: one long post body blanked the whole page. The fixtures are
// what the Ruby serializer emits (spec/ruact/flight/text_framing_fixtures_spec.rb
// writes and guards them).
describe("text rows (Story 17-0d)", () => {
  const FIXTURES = path.join(import.meta.dirname, "../../../spec/fixtures/flight");
  const read = (name) => fs.readFileSync(path.join(FIXTURES, name));
  const expected = JSON.parse(read("text_framing_expected.json").toString("utf8"));

  const rowsOf = (chunks) => {
    const rows = new Map();
    const parser = createRowParser(({ id, row }) => rows.set(id, row));
    for (const chunk of chunks) parser.push(chunk);
    parser.end();
    return rows;
  };

  it("decodes every value the serializer framed, byte for byte", () => {
    const tree = createFromFlightPayload(read("text_framing.txt").toString("utf8"), MODULE_REGISTRY);
    expect(tree).toEqual(expected);
  });

  it("puts long text inside Suspense content where the deferred row points", () => {
    const tree = createFromFlightPayload(read("text_framing_suspense.txt").toString("utf8"), MODULE_REGISTRY);
    const deferred = tree.props.children.type; // the already-arrived deferred row, wrapped
    expect(deferred().props.children).toBe(expected.multibyte);
  });

  it("does not depend on where the network splits the bytes", () => {
    const bytes = new Uint8Array(read("text_framing.txt"));
    const whole = rowsOf([bytes]);

    // Every single split point: inside ids, `T` lengths, text bodies and
    // multibyte code points, and between rows.
    for (let cut = 1; cut < bytes.length; cut += 1) {
      const split = rowsOf([bytes.subarray(0, cut), bytes.subarray(cut)]);
      expect(split).toEqual(whole);
    }

    // And one byte at a time.
    expect(rowsOf([...bytes].map((b) => Uint8Array.of(b)))).toEqual(whole);
  });

  it("refuses a truncated text row instead of rendering part of the page", () => {
    const bytes = new Uint8Array(read("text_framing.txt"));
    const firstText = Buffer.from(bytes).indexOf(":T") + 10;
    expect(() => rowsOf([bytes.subarray(0, firstText)])).toThrow(/Truncated Flight payload/);
  });

  it("refuses a malformed text length", () => {
    const enc = new TextEncoder();
    expect(() => rowsOf([enc.encode("1:Tzz,abc0:\"$T1\"\n")])).toThrow(/Malformed text row length/);
  });

  it("names a text reference whose row never arrived", () => {
    expect(() => createFromFlightPayload('0:{"body":"$T7"}\n', MODULE_REGISTRY))
      .toThrow(/Text row 7 is referenced but was never received/);
  });

  it("skips a stray line without a colon instead of losing the row after it", () => {
    const rows = rowsOf([new TextEncoder().encode('garbage\n0:{"a":1}\n')]);
    expect(rows.get(0)).toEqual({ kind: "model", value: { a: 1 } });
  });

  it("reads a large row arriving in small chunks in linear time", () => {
    const big = JSON.stringify({ items: Array.from({ length: 60000 }, (_, i) => ({ id: i, name: `item ${i}` })) });
    const bytes = new TextEncoder().encode(`0:${big}\n`);
    const chunks = [];
    for (let i = 0; i < bytes.length; i += 4096) chunks.push(bytes.subarray(i, i + 4096));
    const started = performance.now();
    const rows = rowsOf(chunks);
    expect(rows.get(0).value.items).toHaveLength(60000);
    // ~2.3 MB in 4 KB chunks; quadratic re-copying took seconds.
    expect(performance.now() - started).toBeLessThan(1000);
  });

  it("still reads a last row that lost its trailing newline", () => {
    const rows = rowsOf([new TextEncoder().encode('0:{"a":1}')]);
    expect(rows.get(0)).toEqual({ kind: "model", value: { a: 1 } });
  });
});

// Story 17-0c — the serializer emits Ruby Time/DateTime as "$D<ISO>" and
// integers beyond ±(2^53 − 1) as "$n<decimal>". Components got the marker
// strings. The fixture is the Ruby serializer's own output
// (spec/ruact/flight/scalar_fixtures_spec.rb writes and guards it).
describe("dates and big integers (Story 17-0c)", () => {
  const FIXTURES = path.join(import.meta.dirname, "../../../spec/fixtures/flight");
  const payload = fs.readFileSync(path.join(FIXTURES, "scalar_round_trip.txt"), "utf8");
  const expected = JSON.parse(fs.readFileSync(path.join(FIXTURES, "scalar_round_trip_expected.json"), "utf8"));

  // Expected JSON tags what JSON cannot hold: { date: ISO } and { bigint: "…" }.
  const revive = (value) => {
    if (Array.isArray(value)) return value.map(revive);
    if (value && typeof value === "object") {
      if ("date" in value) return new Date(value.date);
      if ("bigint" in value) return BigInt(value.bigint);
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, revive(v)]));
    }
    return value;
  };

  it("rebuilds every value with its JS type, nested ones included", () => {
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);
    expect(tree).toEqual(revive(expected));
  });

  it("gives a Date the same instant, offset applied, to the millisecond", () => {
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);
    expect(tree.time).toBeInstanceOf(Date);
    expect(tree.time.toISOString()).toBe("2026-09-08T12:30:45.123Z");
    expect(tree.zoned.toISOString()).toBe("2026-09-08T12:30:00.000Z");
  });

  it("keeps safe integers as numbers and only the unsafe ones as BigInt", () => {
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);
    expect(typeof tree.max_safe).toBe("number");
    expect(typeof tree.min_safe).toBe("number");
    expect(typeof tree.big).toBe("bigint");
    expect(tree.big).toBe(9007199254740993n);
    expect(tree.negative_big).toBe(-18446744073709551616n);
  });

  it("leaves a literal string that starts with $D a string", () => {
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);
    expect(tree.literal).toBe("$D2026-01-01 is a string");
  });
});

// A server-rendered tree has unkeyed siblings (an <h1> beside a component, the
// rows of an ERB loop). React logged "Each child in a list should have a
// unique key" for the Getting Started page itself. Elements in an array are
// keyed by position — the key React uses implicitly — unless the wire has one.
describe("sibling keys", () => {
  it("keys unkeyed siblings at the root and in children by their position", () => {
    const payload = [
      '1:I["/TaskList.jsx","TaskList"]',
      '0:[["$","h1",null,{"children":"Hello"}],["$","$L1",null,{"tasks":[]}],["$","ul",null,{"children":[["$","li",null,{"children":"a"}],["$","li","explicit",{"children":"b"}]]}]]',
      "",
    ].join("\n");
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);

    expect(tree.map((el) => el.key)).toEqual(["0", "1", "2"]);
    expect(tree[2].props.children.map((el) => el.key)).toEqual(["0", "explicit"]);
  });

  it("leaves a single element and data arrays alone", () => {
    const tree = createFromFlightPayload(payloadWithProps({ tasks: [{ id: 1 }, { id: 2 }] }), MODULE_REGISTRY);
    expect(tree.key).toBeNull();
    expect(tree.props.tasks).toEqual([{ id: 1 }, { id: 2 }]);
  });
});
