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
//   2. Children — the shapes the server actually emits still build. The server
//      collapses a single child before the wire (`html_converter.rb:188`, and
//      the Suspense path at `:202`), so the client is not the place that
//      normalizes children.
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

    const { posts } = tree.props;
    expect(Array.isArray(posts)).toBe(true);
    expect(posts).toHaveLength(1);
    expect(() => [...posts]).not.toThrow();
  });
});

describe("Story 17.0a — children shapes the server emits still build", () => {
  it("a single child arrives collapsed, because the SERVER collapsed it", () => {
    // `html_converter.rb:188` writes `children` as the child itself when there
    // is exactly one. The client receives a string/element, never a 1-array.
    const tree = buildTree(
      ["$", "div", null, { children: "hi" }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(tree.props.children).toBe("hi");
  });

  it("multiple children arrive as an array", () => {
    const tree = buildTree(
      ["$", "ul", null, { children: [["$", "li", "a", { children: "one" }], ["$", "li", "b", { children: "two" }]] } ],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.children)).toBe(true);
    expect(tree.props.children).toHaveLength(2);
  });

  it("a children array that DOES arrive with one element stays an array", () => {
    // Not a shape the current server emits, but the client must not silently
    // change arity — that is the whole defect, and `children` is not special.
    const tree = buildTree(
      ["$", "ul", null, { children: [["$", "li", "a", { children: "only" }]] }],
      EMPTY_ROWS,
      MODULE_REGISTRY,
    );

    expect(Array.isArray(tree.props.children)).toBe(true);
    expect(tree.props.children).toHaveLength(1);
  });

  it("an element with no children has no children prop", () => {
    const tree = buildTree(["$", "br", null, {}], EMPTY_ROWS, MODULE_REGISTRY);

    expect(tree.props.children).toBeUndefined();
  });
});

describe("Story 17.0a — the contract, driven by a gem-produced fixture", () => {
  // The bytes were written by the Ruby serializer, not typed here.
  // `spec/ruact/flight/serializer_spec.rb` ("single-element array prop
  // survives the wire (Story 17.0a)") produces and pins them; if the server's
  // wire shape ever changes, that spec fails on the Ruby side and this one
  // fails on the JS side — one defect, both sides of the submodule boundary.
  // Pattern established by Story 5.2.
  const FIXTURE = path.join(
    import.meta.dirname,
    "../../../spec/fixtures/flight/single_element_array_prop.txt",
  );

  it("the fixture the gem wrote rebuilds as a one-element array", () => {
    const payload = fs.readFileSync(FIXTURE, "utf8");
    const tree = createFromFlightPayload(payload, MODULE_REGISTRY);

    expect(Array.isArray(tree.props.posts)).toBe(true);
    expect(tree.props.posts).toEqual([{ id: 1, title: "First post" }]);
  });
});
