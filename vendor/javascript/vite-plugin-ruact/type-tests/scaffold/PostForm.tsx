"use client";

// Post form — shared by `new` (initial == null) and `edit` (initial
// == the serialized record). Each field renders the shadcn control mapped to its
// attribute type (Input / Textarea / Switch / Select), labelled, with the FR98
// server error surfaced inline beneath it. Submits through the v2 action
// accessors: createPost (POST /posts) or updatePost (PATCH /posts/:id). On
// success the controller drives navigation SERVER-SIDE via `redirect_to`
// (the `$redirect` the runtime follows) — there is no client URL building here.
// On a validation failure the SAME response carries the FR98 attribute-keyed
// `errors` map, surfaced inline per field (the client stays on the form).
//
// The `@/components/ui/*` primitives below are installed by Story 10.5; a freshly
// scaffolded app will not resolve them until then (the live demo is Story 10.7).
//
// Client-side validation is intentionally NOT here — it is server-only with a
// full round-trip (Story 10.6 adds the model-validation bridge). The controlled
// `useState` keeps this dependency-free; to adopt rich client validation later,
// swap the controlled state for react-hook-form's `useForm` + shadcn `<Form>` and
// feed these same FR98 `errors` into `setError` per key (opt-in — not the default).
import { useState, type FormEvent } from "react";
import { createPost, updatePost } from "@/.ruact/server-functions";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_on: string | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract: `initial` is OPTIONAL (`new` omits it,
// `edit` passes the serialized record); each `references` field adds an
// optional `<name>Options` prop the new/edit views pass. A typo'd prop name
// fails at preprocess time instead of silently arriving as `undefined`.
export const __ruactContract = {
  props: { initial: "optional", authorOptions: "optional" },
};

export function PostForm({ initial = null, authorOptions = [] }: { initial?: PostRow | null; authorOptions?: { id: number; label: string }[] }) {
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
  const [title, setTitle] = useState(String(initial?.title ?? ""));
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
  const [body, setBody] = useState(String(initial?.body ?? ""));
  const [published, setPublished] = useState(Boolean(initial?.published ?? false));
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
  const [views, setViews] = useState(String(initial?.views ?? ""));
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
  const [publishedOn, setPublishedOn] = useState(String(initial?.published_on ?? ""));
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
  const [publishedAt, setPublishedAt] = useState(String(initial?.published_at ?? ""));
  // String-valued state: native/shadcn controls bind `string` (numbers + refs
  // arrive on the row as numbers, so coerce here). The controller re-coerces.
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
    <form onSubmit={handleSubmit} className="mx-auto max-w-xl space-y-6 px-4 py-8">
      <h1 className="text-2xl font-semibold tracking-tight">
        {initial != null ? `Edit Post #${initial.id}` : "New Post"}
      </h1>

      {errorsFor("base").length > 0 && (
        <div className="rounded-md border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          <ul className="list-disc space-y-1 pl-4">
            {errorsFor("base").map((message, i) => (
              <li key={i}>{message}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="space-y-2">
        <Label htmlFor="title">Title</Label>
        <Input
          id="title"
          type="text"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          disabled={saving}
        />
        {errorsFor("title").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <Label htmlFor="body">Body</Label>
        <Textarea
          id="body"
          value={body}
          onChange={(e) => setBody(e.target.value)}
          disabled={saving}
        />
        {errorsFor("body").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <div className="flex items-center gap-2">
          <Switch
            id="published"
            checked={published}
            onCheckedChange={setPublished}
            disabled={saving}
          />
          <Label htmlFor="published">Published</Label>
        </div>
        {errorsFor("published").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <Label htmlFor="views">Views</Label>
        <Input
          id="views"
          type="number"
          value={views}
          onChange={(e) => setViews(e.target.value)}
          disabled={saving}
        />
        {errorsFor("views").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <Label htmlFor="published_on">Published on</Label>
        <Input
          id="published_on"
          type="date"
          value={publishedOn}
          onChange={(e) => setPublishedOn(e.target.value)}
          disabled={saving}
        />
        {errorsFor("published_on").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <Label htmlFor="published_at">Published at</Label>
        <Input
          id="published_at"
          type="datetime-local"
          value={publishedAt}
          onChange={(e) => setPublishedAt(e.target.value)}
          disabled={saving}
        />
        {errorsFor("published_at").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="space-y-2">
        <Label htmlFor="author_id">Author</Label>
        {/* Eager <Select> of controller-provided options (ivar → `authorOptions` prop),
            capped at the generator's REFERENCE_OPTIONS_LIMIT. For a parent set
            larger than that, swap this for a server-search combobox backed by a
            parent-options read query (opt-in follow-up — that query is out of this
            scaffold's scope since the parent model isn't scaffolded here). */}
        <Select
          value={authorId}
          onValueChange={setAuthorId}
          disabled={saving}
        >
          <SelectTrigger id="author_id">
            <SelectValue placeholder="Select author" />
          </SelectTrigger>
          <SelectContent>
            {authorOptions.map((option) => (
              <SelectItem key={option.id} value={String(option.id)}>
                {option.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {errorsFor("author_id").map((message, i) => (
          <p key={i} className="text-sm text-destructive">{message}</p>
        ))}
      </div>

      <div className="flex items-center gap-3 pt-2">
        <Button type="submit" disabled={saving}>
          {saving ? "Saving…" : initial != null ? "Update post" : "Create post"}
        </Button>
        <Button variant="outline" asChild>
          <a href={initial != null ? `/posts/${initial.id}` : "/posts"}>Cancel</a>
        </Button>
      </div>
    </form>
  );
}
