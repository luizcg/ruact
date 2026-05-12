# Flight Wire Format Fixtures

This directory contains fixture files used to test the Flight wire format serializer. Each `.txt` file contains the exact byte output that `Ruact::Flight::Renderer.render` is expected to produce for a given Ruby input.

---

## Wire Format Reference

The React Flight wire protocol encodes a component tree as a series of newline-terminated rows:

```
<hex-id>:<payload>\n         # model row — a JSON value at position <hex-id>
<hex-id>:I<json-array>\n     # import row — registers a client module: [moduleId, exportName, chunks]
<hex-id>:E<json-error>\n     # error row — encodes a serialized error object
```

- **Row `0`** is always the root — the main React element tree returned to the client.
- **Import rows (`I` rows)** always appear *before* the model rows that reference them.
- Hex IDs start at `0` for the root and increment (`1`, `2`, `a`, `b`, …) for each additional row.

### Worked Example — `client_reference.txt`

Ruby input:
```ruby
manifest = Ruact::ClientManifest.new({"LikeButton" => {moduleId: "/LikeButton.jsx", chunks: ["/LikeButton.jsx"]}})
ref = manifest.reference_for("LikeButton")
Ruact::Flight::Renderer.render(ref, manifest)
```

Expected output (`client_reference.txt`):
```
1:I["/LikeButton.jsx","LikeButton",["/LikeButton.jsx"]]
0:["$","$L1",null,{}]
```

- Row `1` is the import row — it tells React where to find `LikeButton`.
- Row `0` is the root element — `["$","$L1",null,{}]` is a React element whose type is `$L1` (a reference to import row 1), with `null` key and empty props `{}`.

---

## How to assert on Flight output

Three RSpec matcher modes live in `spec/support/matchers/flight_fixture_matcher.rb`. Pick the mode that names what you actually care about — defaulting to `match_flight_structure` for new specs avoids the cosmetic-change brittleness that bit Phase 1 (a `JSON.generate` tweak broke 30+ specs at once).

| Mode | When to use | What it tolerates | Failure shape |
|---|---|---|---|
| `match_flight_fixture(name)` | The wire format itself is the contract — bytes-for-bytes guard. Use for serializer escape rules, ordering invariants, or any test where "the output looks exactly like this" is the assertion. | Nothing — exact `==` against the fixture file. | Inspected expected vs. actual strings (whitespace and escapes visible). |
| `match_flight_structure(expected)` | The parsed semantics are the contract — change-tolerant. Use for round-tripping tests, scaffolding, end-to-end render tests, and any case where JSON key reordering or whitespace tweaks should not break the spec. | JSON key insertion order inside payload hashes; whitespace inside JSON; relative ordering among `:import` rows (which Flight treats as an unordered set). Cross-class row order (imports → models → deferred → errors) is **preserved** because the wire protocol depends on it. | Row-indexed diff naming the differing field path (e.g. `Row 0 (model) differs at .payload[0]:`). |
| `include_flight_row(predicate)` | A specific shape must appear regardless of order or siblings. Use for concurrency tests, partial assertions in multi-row outputs, or "this row exists somewhere" checks. | Sibling rows; ordering. Predicate is subset-matched (only the keys you list are compared). | Predicate inspect + a list of every parsed row with id/class/payload preview. |

### Worked examples

Each example is a complete RSpec assertion you can paste into a spec file (above `RSpec.describe` blocks where the matchers are autoloaded by `spec_helper`).

**`match_flight_fixture` — wire-format contract guard:**
```ruby
serialized = "0:\"$$danger\"\n"
expect(serialized).to match_flight_fixture("string_dollar_escape")
# Asserts byte-for-byte against `string_dollar_escape.txt` — proves the `$` → `$$` escape rule.
```

**`match_flight_structure` — parsed-semantics assertion:**
```ruby
wire = %(1:I["/LikeButton.jsx","LikeButton",["/LikeButton.jsx"]]\n) +
       %(0:["$","$L1",null,{"postId":42}]\n)

expect(wire).to match_flight_structure([
  { id: 1, class: :import, payload: ["/LikeButton.jsx", "LikeButton", ["/LikeButton.jsx"]] },
  { id: 0, class: :model,  payload: ["$", "$L1", nil, { "postId" => 42 }] }
])
# Passes even if `JSON.generate` re-orders props later — what matters is that postId=42 round-trips.
```

**`include_flight_row` — ordering-independent presence check:**
```ruby
wire = %(0:["$","CounterButton",null,{"initialCount":0}]\n)

expect(wire).to include_flight_row(
  class: :model,
  payload: hash_including("initialCount" => 0)
)
# Used in concurrency specs where multiple threads emit interleaved rows; only the row's shape matters.
```

### ❌ Avoid / ✅ Prefer

```ruby
❌ expect(output).to include('"postId":42')   # cosmetic-change brittle
✅ expect(output).to include_flight_row(class: :model, payload: hash_including("postId" => 42))
```

A future `JSON.generate` change that emits keys in different insertion order (`{"label":"x","postId":42}` instead of `{"postId":42,"label":"x"}`) breaks the literal substring match. The structural form parses the row and compares hashes by key-set, so it survives the cosmetic change.

### When a fixture spec fails after a serializer change

If `match_flight_fixture` fails after touching `Ruact::Flight::Serializer`, that's by design — the wire format **is** the contract for those fixtures. Either the change is intentional (update the fixture file and the CHANGELOG) or it isn't (revert). Don't switch the spec to `match_flight_structure` to "make it green"; that hides the regression that fixture mode is designed to catch.

---

## Fixture File Inventory

| File | What it tests |
|------|---------------|
| `nil.txt` | Ruby `nil` serializes to the JSON `null` literal in row 0 |
| `boolean_true.txt` | Ruby `true` serializes to the JSON `true` literal |
| `boolean_false.txt` | Ruby `false` serializes to the JSON `false` literal |
| `number_integer.txt` | Ruby integer (e.g. `42`) serializes to a bare JSON number |
| `number_float.txt` | Ruby float (e.g. `3.14`) serializes to a bare JSON float |
| `bigint.txt` | Ruby integer above `MAX_SAFE_INTEGER` (`2**53`) serializes to `"$n<decimal>"` so the JS client can rebuild a `BigInt` |
| `nan.txt` | `Float::NAN` serializes to `"$NaN"` (JSON has no NaN literal; Flight uses the `$`-prefix sentinel) |
| `infinity.txt` | `Float::INFINITY` serializes to `"$Infinity"` |
| `negative_infinity.txt` | `-Float::INFINITY` serializes to `"$-Infinity"` |
| `undefined.txt` | The `:undefined` symbol sentinel serializes to `"$undefined"` so the JS client decodes it as `undefined` (JSON has no undefined literal) |
| `string_basic.txt` | Plain Ruby string serializes to a JSON double-quoted string |
| `string_dollar_escape.txt` | Strings starting with `$` are escaped to `$$…` to avoid collision with Flight's `$L` reference syntax |
| `array.txt` | Ruby array serializes to a JSON array in row 0 |
| `hash.txt` | Ruby hash serializes to a JSON object in row 0 |
| `client_reference.txt` | A `ClientReference` (no props) produces an import row (`I`) + root element referencing `$L1` |
| `client_component_with_props.txt` | A `ClientReference` with props passes them as the fourth element of the root array |
| `react_element_no_props.txt` | A `ReactElement` with no props produces `["$","<tag>",null,{}]` in row 0 |
| `as_json_object.txt` | An object responding to `as_json` is serialized via that method; if it resolves to a `ClientReference`, import + root rows are emitted |
| `serializable_object.txt` | An object including `Ruact::Serializable` and declaring `ruact_props` serializes only the declared props |
| `redirect_row.txt` | A redirect instruction serializes to a JSON object with `redirectUrl` and `redirectType` keys in row 0 |

---

## Adding a New Fixture

See the [Fixture-First Workflow](../../../CONTRIBUTING.md#fixture-first-workflow-adding-a-new-serializable-type) section in `CONTRIBUTING.md` for the full four-step process.

Quick reference:

1. Create `spec/fixtures/flight/<type_name>.txt` with the expected wire bytes.
2. Write a failing spec using `match_flight_fixture("<type_name>")`.
3. Implement the type handler in `flight/serializer.rb`.
4. Run `bundle exec rspec` — the new spec must pass, full suite must have no regressions.
