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

## How `match_flight_fixture` Works

The custom RSpec matcher is defined in `spec/support/matchers/flight_fixture_matcher.rb`:

```ruby
expect(output).to match_flight_fixture("nil")
```

This reads `spec/fixtures/flight/nil.txt` and performs an **exact string comparison** against `output`. There is no normalisation — whitespace, newlines, and ordering must match exactly.

### Failure output

When a fixture does not match, the failure message shows both the expected (fixture file content) and actual (serializer output) as inspected strings, making it easy to spot differences in whitespace or character escaping.

---

## Fixture File Inventory

| File | What it tests |
|------|---------------|
| `nil.txt` | Ruby `nil` serializes to the JSON `null` literal in row 0 |
| `boolean_true.txt` | Ruby `true` serializes to the JSON `true` literal |
| `boolean_false.txt` | Ruby `false` serializes to the JSON `false` literal |
| `number_integer.txt` | Ruby integer (e.g. `42`) serializes to a bare JSON number |
| `number_float.txt` | Ruby float (e.g. `3.14`) serializes to a bare JSON float |
| `string_basic.txt` | Plain Ruby string serializes to a JSON double-quoted string |
| `string_dollar_escape.txt` | Strings starting with `$` are escaped to `$$…` to avoid collision with Flight's `$L` reference syntax |
| `array.txt` | Ruby array serializes to a JSON array in row 0 |
| `hash.txt` | Ruby hash serializes to a JSON object in row 0 |
| `client_reference.txt` | A `ClientReference` (no props) produces an import row (`I`) + root element referencing `$L1` |
| `client_component_with_props.txt` | A `ClientReference` with props passes them as the fourth element of the root array |
| `react_element_no_props.txt` | A `ReactElement` with no props produces `["$","<tag>",null,{}]` in row 0 |
| `as_json_object.txt` | An object responding to `as_json` is serialized via that method; if it resolves to a `ClientReference`, import + root rows are emitted |
| `serializable_object.txt` | An object including `Ruact::Serializable` and declaring `rsc_props` serializes only the declared props |
| `redirect_row.txt` | A redirect instruction serializes to a JSON object with `redirectUrl` and `redirectType` keys in row 0 |

---

## Adding a New Fixture

See the [Fixture-First Workflow](../../../CONTRIBUTING.md#fixture-first-workflow-adding-a-new-serializable-type) section in `CONTRIBUTING.md` for the full four-step process.

Quick reference:

1. Create `spec/fixtures/flight/<type_name>.txt` with the expected wire bytes.
2. Write a failing spec using `match_flight_fixture("<type_name>")`.
3. Implement the type handler in `flight/serializer.rb`.
4. Run `bundle exec rspec` — the new spec must pass, full suite must have no regressions.
