"use client";

// Post list — a shadcn DataTable. The collection arrives as a
// SERVER-RENDERED prop (`posts`); there is no client query for the initial
// render. A query only enters when the *client* drives the read: the search box
// calls useQuery(searchPosts, { q }) and swaps in filtered rows as you type.
// Per-row delete drives a controlled PostDeleteDialog (DELETE
// /posts/:id via the destroyPost action); on `{ ok: true }` the row is
// removed from the local rows IN PLACE (no reload, no URL built). Column sorting
// is CLIENT-ONLY — the dataset is the index payload; server-side sort/pagination
// is Phase-3 territory.
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

// Pull a human-readable message out of the structured-error response the
// destroyPost action throws on failure. The runtime raises a
// RuactActionError carrying the parsed body; the gem's structured-error
// middleware shapes `message` (the exception message in development, the generic
// server message in production). Returns undefined when no message is present, so
// the dialog can fall back to its own generic copy.
function deleteErrorMessage(error: unknown): string | undefined {
  const body =
    error != null && typeof error === "object"
      ? (error as { body?: unknown }).body
      : undefined;
  if (body != null && typeof body === "object") {
    const message = (body as { message?: unknown }).message;
    if (typeof message === "string" && message.length > 0) return message;
  }
  if (error instanceof Error && error.message.length > 0) return error.message;
  return undefined;
}

// Per-row actions (AC5) — Edit + a Delete TRIGGER that opens the controlled
// AlertDialog. Each row owns its OWN `open` state (one independent useState), so
// the dialog opens for exactly one row. `onConfirm` calls destroyPost
// and, on success, asks the List to drop the row in place via `onDeleted`. The
// same component renders BOTH the inline (≥ md) and the overflow-menu (< md)
// layouts. The trigger is never unmounted, so Radix returns focus to it on close.
function RowActions({ record, onDeleted }: {
  record: PostRow;
  onDeleted: (id: number) => void;
}) {
  const [open, setOpen] = useState(false);

  async function onConfirm(): Promise<{ ok: boolean; error?: string }> {
    try {
      await destroyPost({ id: record.id });
      // Success: in-list `{ ok: true }` → remove the row; the documented
      // delete-from-show `{ "$redirect" }` alternative was already followed by
      // the accessor (this component then unmounts harmlessly).
      onDeleted(record.id);
      setOpen(false);
      return { ok: true };
    } catch (error) {
      // Failure → keep the dialog open and surface the message inline.
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
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" aria-label="Open actions menu">…</Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem asChild>
              <a href={`/posts/${record.id}/edit`}>Edit</a>
            </DropdownMenuItem>
            {/* Open the AlertDialog only AFTER the menu's own close settles:
                a DropdownMenuItem's default onSelect closes the menu, which would
                tear the dialog down mid-open. preventDefault keeps our state
                authoritative, then we open the dialog. */}
            <DropdownMenuItem
              className="text-destructive"
              onSelect={(event) => {
                event.preventDefault();
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
  // The server-rendered list is LOCAL state so a successful delete can drop the
  // row in place (golden single-source filter — no dual cache while searching).
  const [serverRows, setServerRows] = useState(posts);

  const [q, setQ] = useState("");
  const searching = q.trim().length > 0;

  // Client-driven read (AC5) — only meaningful while searching. When q is blank
  // the box is idle and we fall back to the server-rendered rows.
  const { data: searchData, loading: searchLoading } = useQuery<PostRow[]>(searchPosts, { q: q.trim() });

  const rows = searching ? searchData ?? [] : serverRows;

  // Typed columns config (AC1) — built INSIDE the component (design B) so the
  // actions cell closes over component state (`onDeleted`) to drive the
  // controlled delete dialog + in-list removal, with no change to the DataTable's
  // `{ columns, data }` interface. One column per attribute, the cell renderer
  // keyed on the attribute type: boolean → Badge, numeric → right-aligned, date →
  // locale-formatted, everything else → plain text. Every header is a sortable
  // Button (AC2). The trailing actions column collapses into a … menu under the
  // `md` breakpoint (768px). Memoized once: `onDeleted` only calls the stable
  // `setServerRows`, so the empty dependency list is correct.
  const columns: ColumnDef<PostRow>[] = useMemo(() => {
    const onDeleted = (id: number) =>
      setServerRows((current) => current.filter((row) => row.id !== id));

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
    // `setServerRows` is a stable React setter; the column defs capture nothing
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
      {!searching && serverRows.length === 0 && <p className="text-sm text-muted-foreground">{emptyLabel}</p>}
      {searching && !searchLoading && rows.length === 0 && (
        <p className="text-sm text-muted-foreground">No posts match “{q.trim()}”.</p>
      )}

      {rows.length > 0 && <DataTable columns={columns} data={rows} />}
    </section>
  );
}
