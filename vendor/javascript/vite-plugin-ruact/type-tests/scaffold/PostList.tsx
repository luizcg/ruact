"use client";

// Post list — a shadcn `table` primitive (a styled HTML table) plus a
// small GENERATED client-side sort. There is NO table-engine dependency: the
// scaffold stays dep-free (no react-table runtime), matching the dep-free
// Form and the native date inputs. The collection arrives as a SERVER-RENDERED
// prop (`posts`); there is no client query for the initial render. A query only
// enters when the *client* drives the read: the search box calls
// useQuery(searchPosts, { q }) and swaps in filtered rows as you type.
// Per-row delete drives a controlled PostDeleteDialog (DELETE
// /posts/:id via the destroyPost action); on `{ ok: true }` the row is
// removed from the displayed rows IN PLACE (no reload, no URL built). Column
// sorting is CLIENT-ONLY — the dataset is the index payload; server-side
// sort/pagination is Phase-3 territory.
//
// The `@/components/ui/table` primitive (and the Badge/Button/DropdownMenu
// primitives below) is installed by Story 10.5 (`npx shadcn add table`). A
// freshly scaffolded app will not resolve these until 10.5 lands; that is
// expected (the end-to-end live demo is Story 10.7).
import { useState } from "react";
import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions";
import { PostDeleteDialog } from "./PostDeleteDialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract: `posts` is required. The index view passes
// `<PostList posts={rows} />` (satisfied); a call site that omits it
// fails at preprocess time, not as a silent `undefined` in the browser.
export const __ruactContract = {
  props: { posts: "required" },
};

// Columns whose values are date/datetime strings: the sort compares these by
// epoch time (`new Date(value).getTime()`) rather than lexically, so they order
// chronologically. Generated from the model's date/datetime attributes.
const DATE_KEYS = new Set<string>(["published_at"]);

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

// Per-row actions (AC5) — Edit + a Delete TRIGGER that opens the controlled
// AlertDialog. Each row owns its OWN dialog `open` state (one independent
// useState), so the dialog opens for exactly one row. `onConfirm` calls
// destroyPost and, on a server-owned success, asks the List to drop the row
// in place via `onDeleted`. The same component renders BOTH the inline (≥ md) and
// the overflow-menu (< md) layouts. The trigger is never unmounted, so Radix
// returns focus to it on close.
function RowActions({ record, onDeleted }: {
  record: PostRow;
  onDeleted: (id: number) => void;
}) {
  const [open, setOpen] = useState(false);
  // The overflow menu is CONTROLLED so the Delete item can close it explicitly
  // and open the dialog in the same batch — preventing Radix's default
  // close-autofocus from pulling focus back to the trigger as the dialog mounts.
  const [menuOpen, setMenuOpen] = useState(false);

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
    <div className="flex justify-end">
      {/* ≥ md (768px): inline actions */}
      <div className="hidden items-center gap-2 md:flex">
        <Button variant="ghost" asChild>
          <a href={`/posts/${record.id}/edit`}>Edit</a>
        </Button>
        <Button variant="ghost" className="text-destructive" onClick={() => setOpen(true)}>
          Delete
        </Button>
      </div>
      {/* < md: collapse into a … overflow menu so actions never break layout */}
      <div className="md:hidden">
        <DropdownMenu open={menuOpen} onOpenChange={setMenuOpen}>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" aria-label="Open actions menu">…</Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem asChild>
              <a href={`/posts/${record.id}/edit`}>Edit</a>
            </DropdownMenuItem>
            {/* Close the menu and open the AlertDialog together: preventDefault
                stops the default close (whose autofocus would fight the dialog),
                then we close the menu and open the dialog deterministically. */}
            <DropdownMenuItem
              className="text-destructive"
              onSelect={(event) => {
                event.preventDefault();
                setMenuOpen(false);
                setOpen(true);
              }}
            >
              Delete
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <PostDeleteDialog
        open={open}
        onOpenChange={setOpen}
        post={record}
        onConfirm={onConfirm}
      />
    </div>
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
    <section className="mx-auto max-w-4xl px-4 py-8">
      <div className="mb-4 flex items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold tracking-tight">Posts</h1>
        <Button asChild>
          <a href="/posts/new">+ New post</a>
        </Button>
      </div>

      <input
        type="search"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search posts…"
        className="mb-4 w-full rounded-md border px-3 py-2 text-sm"
      />

      {searching && searchLoading && <p className="text-sm text-muted-foreground">Searching…</p>}
      {!searching && rows.length === 0 && <p className="text-sm text-muted-foreground">{emptyLabel}</p>}
      {searching && !searchLoading && rows.length === 0 && (
        <p className="text-sm text-muted-foreground">No posts match “{q.trim()}”.</p>
      )}

      {sortedRows.length > 0 && (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>
                <Button variant="ghost" onClick={() => toggleSort("id")}>ID</Button>
              </TableHead>
              <TableHead>
                <Button variant="ghost" onClick={() => toggleSort("title")}>
                  Title
                </Button>
              </TableHead>
              <TableHead>
                <Button variant="ghost" onClick={() => toggleSort("body")}>
                  Body
                </Button>
              </TableHead>
              <TableHead>
                <Button variant="ghost" onClick={() => toggleSort("published")}>
                  Published
                </Button>
              </TableHead>
              <TableHead>
                <div className="text-right">
                  <Button variant="ghost" onClick={() => toggleSort("views")}>
                    Views
                  </Button>
                </div>
              </TableHead>
              <TableHead>
                <Button variant="ghost" onClick={() => toggleSort("published_at")}>
                  Published at
                </Button>
              </TableHead>
              <TableHead>
                <div className="text-right">
                  <Button variant="ghost" onClick={() => toggleSort("author_id")}>
                    Author
                  </Button>
                </div>
              </TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {sortedRows.map((row) => (
              <TableRow key={row.id}>
                <TableCell>
                  <a href={`/posts/${row.id}`} className="font-medium underline-offset-4 hover:underline">
                    {row.id}
                  </a>
                </TableCell>
                <TableCell>
                  <span>{String(row.title ?? "")}</span>
                </TableCell>
                <TableCell>
                  <span>{String(row.body ?? "")}</span>
                </TableCell>
                <TableCell>
                  <Badge variant={row.published ? "default" : "secondary"}>{row.published ? "Yes" : "No"}</Badge>
                </TableCell>
                <TableCell>
                  <div className="text-right tabular-nums">{String(row.views ?? "")}</div>
                </TableCell>
                <TableCell>
                  <span>{row.published_at ? new Date(String(row.published_at)).toLocaleString() : ""}</span>
                </TableCell>
                <TableCell>
                  <div className="text-right tabular-nums">{String(row.author_id ?? "")}</div>
                </TableCell>
                <TableCell>
                  <RowActions record={row} onDeleted={onDeleted} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </section>
  );
}
