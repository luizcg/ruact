"use client";

// Post form — shared by `new` (initial == null) and `edit` (initial
// == the serialized record). DESIGN-SYSTEM-AGNOSTIC (Story 14.4 / FR103): every
// field renders a plain, native HTML control mapped to its attribute type
// (input / textarea / checkbox / select), labelled, with the FR98 server error
// surfaced inline beneath it — NO shadcn/ui, NO Tailwind, browser-default styling.
// Submits through the v2 action accessors: createPost (POST /posts) or
// updatePost (PATCH /posts/:id). On success the controller drives navigation
// SERVER-SIDE via `redirect_to` (the `$redirect` the runtime follows) — there is
// no client URL building here. On a validation failure the SAME response carries
// the FR98 attribute-keyed `errors` map, surfaced inline per field (the client
// stays on the form). (The richer shadcn controls are the opt-in `--shadcn` path
// — Story 14.5.)
//
// Client-side validation is intentionally NOT here — it is server-only with a
// full round-trip. The controlled `useState` keeps this dependency-free.
import { useState, type FormEvent } from "react";
import { createPost, updatePost } from "@/.ruact/server-functions";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_on: string | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract: `initial` is OPTIONAL (`new` omits it,
// `edit` passes the serialized record); each `references` field adds an
// optional `<name>Options` prop the new/edit views pass. A typo'd prop name
// fails at preprocess time instead of silently arriving as `undefined`.
export const __ruactContract = {
  props: { initial: "optional", authorOptions: "optional" },
};

export function PostForm({ initial = null, authorOptions = [] }: { initial?: PostRow | null; authorOptions?: { id: number; label: string }[] }) {
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [title, setTitle] = useState(String(initial?.title ?? ""));
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [body, setBody] = useState(String(initial?.body ?? ""));
  const [published, setPublished] = useState(Boolean(initial?.published ?? false));
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [views, setViews] = useState(String(initial?.views ?? ""));
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [publishedOn, setPublishedOn] = useState(String(initial?.published_on ?? ""));
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [publishedAt, setPublishedAt] = useState(String(initial?.published_at ?? ""));
  // String-valued state: native controls bind `string` (numbers + refs arrive on
  // the row as numbers, so coerce here). The controller re-coerces.
  const [authorId, setAuthorId] = useState(String(initial?.author_id ?? ""));
  // FR98 — keyed { [attr]: string[] }; `{}` means "no errors" (always present).
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setSaving(true);
    setErrors({});

    const payload = {
      title: title,
      body: body,
      published: published,
      views: views,
      published_on: publishedOn,
      published_at: publishedAt,
      author_id: authorId,
    };

    // On success the server returns a `$redirect` and the runtime navigates
    // away (the code below does not run); on a validation failure we get the
    // keyed `errors` map back instead.
    const result = (initial != null
      ? await updatePost({ id: initial.id, ...payload })
      : await createPost(payload)) as { errors?: Record<string, string[]> } | null;

    setSaving(false);
    if (result && result.errors) {
      setErrors(result.errors);
    }
  }

  const errorsFor = (attr: string) => errors[attr] ?? [];

  return (
    <form onSubmit={handleSubmit}>
      <h1>{initial != null ? `Edit Post #${initial.id}` : "New Post"}</h1>

      {errorsFor("base").length > 0 && (
        <ul>
          {errorsFor("base").map((message, i) => (
            <li key={i}>{message}</li>
          ))}
        </ul>
      )}

      <p>
        <label htmlFor="title">Title</label>
        <input
          id="title"
          type="text"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          disabled={saving}
        />
        {errorsFor("title").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="body">Body</label>
        <textarea
          id="body"
          value={body}
          onChange={(e) => setBody(e.target.value)}
          disabled={saving}
        />
        {errorsFor("body").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="published">
          <input
            id="published"
            type="checkbox"
            checked={published}
            onChange={(e) => setPublished(e.target.checked)}
            disabled={saving}
          />
          {" "}Published
        </label>
        {errorsFor("published").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="views">Views</label>
        <input
          id="views"
          type="number"
          value={views}
          onChange={(e) => setViews(e.target.value)}
          disabled={saving}
        />
        {errorsFor("views").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="published_on">Published on</label>
        <input
          id="published_on"
          type="date"
          value={publishedOn}
          onChange={(e) => setPublishedOn(e.target.value)}
          disabled={saving}
        />
        {errorsFor("published_on").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="published_at">Published at</label>
        <input
          id="published_at"
          type="datetime-local"
          value={publishedAt}
          onChange={(e) => setPublishedAt(e.target.value)}
          disabled={saving}
        />
        {errorsFor("published_at").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <label htmlFor="author_id">Author</label>
        {/* Eager native <select> of controller-provided options (ivar → `authorOptions`
            prop). For a parent set larger than the generator's REFERENCE_OPTIONS_LIMIT,
            swap this for a server-search combobox backed by a parent-options read
            query (opt-in follow-up — that query is out of this scaffold's scope
            since the parent model isn't scaffolded here). */}
        <select
          id="author_id"
          value={authorId}
          onChange={(e) => setAuthorId(e.target.value)}
          disabled={saving}
        >
          <option value="">Select author</option>
          {authorOptions.map((option) => (
            <option key={option.id} value={String(option.id)}>
              {option.label}
            </option>
          ))}
        </select>
        {errorsFor("author_id").map((message, i) => (
          <span key={i}>{message}</span>
        ))}
      </p>

      <p>
        <button type="submit" disabled={saving}>
          {saving ? "Saving…" : initial != null ? "Update post" : "Create post"}
        </button>
        {" "}
        <a href={initial != null ? `/posts/${initial.id}` : "/posts"}>Cancel</a>
      </p>
    </form>
  );
}
