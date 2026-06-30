"use client";

// Post list — a DESIGN-SYSTEM-AGNOSTIC table (Story 14.4 / FR103). The
// default scaffold ships plain, native HTML elements styled by the browser /
// Rails-default CSS — NO shadcn/ui, NO Tailwind, NO table-engine dependency. The
// collection arrives as a SERVER-RENDERED prop (`posts`); there is no client query
// for the initial render. A query only enters when the *client* drives the read:
// the search box calls useQuery(searchPosts, { q }) and swaps in filtered rows as
// you type. Per-row delete drives a controlled PostDeleteDialog (DELETE
// /posts/:id via the destroyPost action); on `{ ok: true }` the row is
// removed from the displayed rows IN PLACE (no reload, no URL built). Column
// sorting is CLIENT-ONLY — the dataset is the index payload; server-side
// sort/pagination is Phase-3 territory. (The richer shadcn DataTable styling is
// the opt-in `--shadcn` path — Story 14.5.)
import { useState } from "react";
import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions";
import { PostDeleteDialog } from "./PostDeleteDialog";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_on: string | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract: `posts` is required. The index view passes
// `<PostList posts={rows} />` (satisfied); a call site that omits it
// fails at preprocess time, not as a silent `undefined` in the browser.
export const __ruactContract = {
  props: { posts: "required" },
};

// Columns whose values are date/datetime strings: the sort compares these by
// epoch time (`new Date(value).getTime()`) rather than lexically, so they order
// chronologically. Generated from the model's date/datetime attributes.
const DATE_KEYS = new Set<string>(["published_on", "published_at"]);

// Generated client-side comparator (no table engine). Sorts a COPY of the rows
// by the active key + direction: `null`/`undefined` always sort LAST (so a blank
// cell never jumps to the top, regardless of direction); date columns compare by
// time, numbers numerically, booleans false-before-true, everything else via a
// locale-aware string compare. The direction flip is applied AFTER the null
// handling, never to it.
function compareRows(
  a: PostRow,
  b: PostRow,
  sort: { key: string; dir: "asc" | "desc" },
): number {
  const av = a[sort.key as keyof PostRow];
  const bv = b[sort.key as keyof PostRow];
  if (av == null && bv == null) return 0;
  if (av == null) return 1;
  if (bv == null) return -1;

  let result: number;
  if (DATE_KEYS.has(sort.key)) {
    result = new Date(String(av)).getTime() - new Date(String(bv)).getTime();
  } else if (typeof av === "number" && typeof bv === "number") {
    result = av - bv;
  } else if (typeof av === "boolean" && typeof bv === "boolean") {
    result = Number(av) - Number(bv);
  } else {
    result = String(av).localeCompare(String(bv));
  }
  return sort.dir === "desc" ? -result : result;
}

// Pull a human-readable message out of the failed-delete result. A thrown
// RuactActionError (non-2xx) carries the parsed structured-error body, whose
// `message` the gem shapes per env (the exception message in development, the
// generic server message in production); a resolved soft-failure may carry a
// top-level `error`/`message`. Returns undefined when none is present, so the
// dialog can fall back to its own generic copy.
function deleteErrorMessage(error: unknown): string | undefined {
  if (error != null && typeof error === "object") {
    const carrier = error as { body?: unknown; error?: unknown; message?: unknown };
    if (carrier.body != null && typeof carrier.body === "object") {
      const message = (carrier.body as { message?: unknown }).message;
      if (typeof message === "string" && message.length > 0) return message;
    }
    if (typeof carrier.error === "string" && carrier.error.length > 0) return carrier.error;
    if (typeof carrier.message === "string" && carrier.message.length > 0) return carrier.message;
  }
  return undefined;
}

// A resolved delete is a SUCCESS only on the server-owned success shapes: the
// in-list default `{ ok: true }`, or the delete-from-show `$redirect` the
// accessor already followed (which resolves to `null`). Any other resolved shape
// (e.g. an explicit `{ ok: false }`) is a non-success the dialog surfaces.
function deleteSucceeded(result: unknown): boolean {
  if (result === null) return true;
  return (
    typeof result === "object" &&
    (result as { ok?: unknown }).ok === true
  );
}

// Per-row actions (AC2) — an Edit link + a Delete TRIGGER that opens the
// controlled dialog. Each row owns its OWN dialog `open` state (one independent
// useState), so the dialog opens for exactly one row. `onConfirm` calls
// destroyPost and, on a server-owned success, asks the List to drop the row
// in place via `onDeleted`. The agnostic default keeps a single inline actions
// cell (the responsive overflow menu is a shadcn refinement deferred to the
// `--shadcn` path — Story 14.5).
function RowActions({ record, onDeleted }: {
  record: PostRow;
  onDeleted: (id: number) => void;
}) {
  const [open, setOpen] = useState(false);

  async function onConfirm(): Promise<{ ok: boolean; error?: string }> {
    try {
      const result = await destroyPost({ id: record.id });
      if (deleteSucceeded(result)) {
        onDeleted(record.id);
        setOpen(false);
        return { ok: true };
      }
      // Resolved but not a success shape → keep the dialog open with the message.
      return { ok: false, error: deleteErrorMessage(result) };
    } catch (error) {
      // Failure (non-2xx structured error) → keep the dialog open, message inline.
      return { ok: false, error: deleteErrorMessage(error) };
    }
  }

  return (
    <span>
      <a href={`/posts/${record.id}/edit`}>Edit</a>
      {" "}
      <button type="button" onClick={() => setOpen(true)}>
        Delete
      </button>

      <PostDeleteDialog
        open={open}
        onOpenChange={setOpen}
        post={record}
        onConfirm={onConfirm}
      />
    </span>
  );
}

export function PostList({
  posts = [],
  emptyLabel = "No posts yet — create one.",
}: { posts?: PostRow[]; emptyLabel?: string }) {
  const [q, setQ] = useState("");
  const searching = q.trim().length > 0;

  // Ids deleted IN PLACE — a single tombstone list (not a second row cache)
  // applied to whichever source is displayed, so a delete removes the row
  // immediately whether it happened on the server-rendered list OR on the live
  // search results.
  const [removedIds, setRemovedIds] = useState<number[]>([]);

  // Sort state (AC2) — the active column key + direction, or null when unsorted
  // (server/insertion order). A new key sorts ascending; clicking the same key
  // again flips asc↔desc.
  const [sort, setSort] = useState<{ key: string; dir: "asc" | "desc" } | null>(null);

  // Client-driven read (AC5) — only meaningful while searching. When q is blank
  // the box is idle and we fall back to the server-rendered rows.
  const { data: searchData, loading: searchLoading } = useQuery<PostRow[]>(searchPosts, { q: q.trim() });

  const source = searching ? searchData ?? [] : posts;
  const rows = removedIds.length === 0 ? source : source.filter((row) => !removedIds.includes(row.id));
  // Always sort a COPY — never mutate the prop/source array.
  const sortedRows = sort ? [...rows].sort((a, b) => compareRows(a, b, sort)) : rows;

  const onDeleted = (id: number) =>
    setRemovedIds((current) => (current.includes(id) ? current : [...current, id]));

  // Set the sort to a new key (ascending), or flip the direction when the active
  // key is clicked again.
  function toggleSort(key: string) {
    setSort((current) =>
      current && current.key === key
        ? { key, dir: current.dir === "asc" ? "desc" : "asc" }
        : { key, dir: "asc" },
    );
  }

  return (
    <section>
      <h1>Posts</h1>
      <p>
        <a href="/posts/new">+ New post</a>
      </p>

      <input
        type="search"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search posts…"
      />

      {searching && searchLoading && <p>Searching…</p>}
      {!searching && rows.length === 0 && <p>{emptyLabel}</p>}
      {searching && !searchLoading && rows.length === 0 && (
        <p>No posts match “{q.trim()}”.</p>
      )}

      {sortedRows.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>
                <button type="button" onClick={() => toggleSort("id")}>ID</button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("title")}>
                  Title
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("body")}>
                  Body
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("published")}>
                  Published
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("views")}>
                  Views
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("published_on")}>
                  Published on
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("published_at")}>
                  Published at
                </button>
              </th>
              <th>
                <button type="button" onClick={() => toggleSort("author_id")}>
                  Author
                </button>
              </th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {sortedRows.map((row) => (
              <tr key={row.id}>
                <td>
                  <a href={`/posts/${row.id}`}>{row.id}</a>
                </td>
                <td>{String(row.title ?? "")}</td>
                <td>{String(row.body ?? "")}</td>
                <td>{row.published ? "Yes" : "No"}</td>
                <td>{String(row.views ?? "")}</td>
                <td>{row.published_on ? new Date(String(row.published_on)).toLocaleString() : ""}</td>
                <td>{row.published_at ? new Date(String(row.published_at)).toLocaleString() : ""}</td>
                <td>{String(row.author_id ?? "")}</td>
                <td>
                  <RowActions record={row} onDeleted={onDeleted} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
