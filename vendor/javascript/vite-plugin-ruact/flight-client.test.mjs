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
// independent (the suite runs in randomized order by project rule).

import { describe, it, expect, beforeEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import {
  buildTree,
  createFromFlightPayload,
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
      payloadWithProps({ tags: ["ruby"] }),
      MODULE_REGISTRY,
    );

    expect(tree.props.tags).toEqual(["ruby"]);
  });

  it("the scaffold's own prop shape survives (issue #62 reproduction)", () => {
    // `<PostList posts={rows} />` with exactly one record — the generated
    // scaffold reads `posts.length` and spreads `[...posts]`, so an object here
    // renders neither the table nor the empty state, and throws on first sort.
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
    expect(tree.props.posts).toEqual([{ id: 1, title: "First post" }]);
  });
});
