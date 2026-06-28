"use client";

// Post list — a shadcn DataTable. The collection arrives as a
// SERVER-RENDERED prop (`posts`); there is no client query for the initial
// render. A query only enters when the *client* drives the read: the search box
// calls useQuery(searchPosts, { q }) and swaps in filtered rows as you type.
// Per-row delete drives a controlled PostDeleteDialog (DELETE
// /posts/:id via the destroyPost action); on `{ ok: true }` the row is
// removed from the displayed rows IN PLACE (no reload, no URL built). Column
// sorting is CLIENT-ONLY — the dataset is the index payload; server-side
// sort/pagination is Phase-3 territory.
//
// The `DataTable` recipe + the shadcn primitives below import from
// `@/components/ui/*`, which Story 10.5 installs (shadcn ships no installable
// DataTable — it is a copy-paste @tanstack/react-table recipe 10.5 templates).
// A freshly scaffolded app will not resolve these until 10.5 lands; that is
// expected (the end-to-end live demo is Story 10.7).
import { useMemo, useState } from "react";
import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions";
import { PostDeleteDialog } from "./PostDeleteDialog";
import { DataTable } from "@/components/ui/data-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { ColumnDef } from "@tanstack/react-table";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract: `posts` is required. The index view passes
// `<PostList posts={rows} />` (satisfied); a call site that omits it
// fails at preprocess time, not as a silent `undefined` in the browser.
export const __ruactContract = {
  props: { posts: "required" },
};

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

  // Client-driven read (AC5) — only meaningful while searching. When q is blank
  // the box is idle and we fall back to the server-rendered rows.
  const { data: searchData, loading: searchLoading } = useQuery<PostRow[]>(searchPosts, { q: q.trim() });

  const source = searching ? searchData ?? [] : posts;
  const rows = removedIds.length === 0 ? source : source.filter((row) => !removedIds.includes(row.id));

  // Typed columns config (AC1) — built INSIDE the component (design B) so the
  // actions cell closes over component state (`onDeleted`) to drive the
  // controlled delete dialog + in-list removal, with no change to the DataTable's
  // `{ columns, data }` interface. One column per attribute, the cell renderer
  // keyed on the attribute type: boolean → Badge, numeric → right-aligned, date →
  // locale-formatted, everything else → plain text. Every header is a sortable
  // Button (AC2). The trailing actions column collapses into a … menu under the
  // `md` breakpoint (768px). Memoized once: `onDeleted` only calls the stable
  // `setRemovedIds`, so the empty dependency list is correct.
  const columns: ColumnDef<PostRow>[] = useMemo(() => {
    const onDeleted = (id: number) =>
      setRemovedIds((current) => (current.includes(id) ? current : [...current, id]));

    return [
      {
        accessorKey: "id",
        header: ({ column }) => (
          <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
            ID
          </Button>
        ),
        cell: ({ row }) => (
          <a href={`/posts/${row.original.id}`} className="font-medium underline-offset-4 hover:underline">
            {row.original.id}
          </a>
        ),
      },
      {
        accessorKey: "title",
        header: ({ column }) => (
          <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
            Title
          </Button>
        ),
        cell: ({ row }) => <span>{String(row.getValue("title") ?? "")}</span>,
      },
      {
        accessorKey: "body",
        header: ({ column }) => (
          <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
            Body
          </Button>
        ),
        cell: ({ row }) => <span>{String(row.getValue("body") ?? "")}</span>,
      },
      {
        accessorKey: "published",
        header: ({ column }) => (
          <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
            Published
          </Button>
        ),
        cell: ({ row }) => {
          const value = row.getValue("published");
          return <Badge variant={value ? "default" : "secondary"}>{value ? "Yes" : "No"}</Badge>;
        },
      },
      {
        accessorKey: "views",
        header: ({ column }) => (
          <div className="text-right">
            <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
              Views
            </Button>
          </div>
        ),
        cell: ({ row }) => (
          <div className="text-right tabular-nums">{String(row.getValue("views") ?? "")}</div>
        ),
      },
      {
        accessorKey: "published_at",
        header: ({ column }) => (
          <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
            Published at
          </Button>
        ),
        cell: ({ row }) => {
          const value = row.getValue("published_at");
          return <span>{value ? new Date(String(value)).toLocaleString() : ""}</span>;
        },
      },
      {
        accessorKey: "author_id",
        header: ({ column }) => (
          <div className="text-right">
            <Button variant="ghost" onClick={() => column.toggleSorting(column.getIsSorted() === "asc")}>
              Author
            </Button>
          </div>
        ),
        cell: ({ row }) => (
          <div className="text-right tabular-nums">{String(row.getValue("author_id") ?? "")}</div>
        ),
      },
      {
        id: "actions",
        enableSorting: false,
        cell: ({ row }) => <RowActions record={row.original} onDeleted={onDeleted} />,
      },
    ];
    // `setRemovedIds` is a stable React setter; the column defs capture nothing
    // else from render, so the columns are built exactly once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

      {rows.length > 0 && <DataTable columns={columns} data={rows} />}
    </section>
  );
}
