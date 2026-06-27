"use client";

// Post list — a shadcn DataTable. The collection arrives as a
// SERVER-RENDERED prop (`posts`); there is no client query for the initial
// render. A query only enters when the *client* drives the read: the search box
// calls useQuery(searchPosts, { q }) and swaps in filtered rows as you type.
// Per-row delete is delegated to PostDeleteDialog (DELETE /posts/:id via the
// destroyPost action). Column sorting is CLIENT-ONLY — the dataset is the
// index payload; server-side sort/pagination is Phase-3 territory.
//
// The `DataTable` recipe + the shadcn primitives below import from
// `@/components/ui/*`, which Story 10.5 installs (shadcn ships no installable
// DataTable — it is a copy-paste @tanstack/react-table recipe 10.5 templates).
// A freshly scaffolded app will not resolve these until 10.5 lands; that is
// expected (the end-to-end live demo is Story 10.7).
import { useState } from "react";
import { search as searchPosts, useQuery } from "@/.ruact/server-functions";
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

// Typed columns config (AC1) — one column per attribute, the cell renderer keyed
// on the attribute type: boolean → Badge, numeric → right-aligned, date →
// locale-formatted, everything else → plain text. Every header is a sortable
// Button (AC2). The trailing actions column (AC3) keeps Edit + delete reachable
// and collapses into a … menu under the `md` breakpoint (768px) so it never
// pushes the data columns out of layout on narrow viewports.
const columns: ColumnDef<PostRow>[] = [
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
    cell: ({ row }) => {
      const record = row.original;
      return (
        <div className="flex justify-end">
          {/* ≥ md (768px): inline actions */}
          <div className="hidden items-center gap-2 md:flex">
            <Button variant="ghost" asChild>
              <a href={`/posts/${record.id}/edit`}>Edit</a>
            </Button>
            <PostDeleteDialog post={record} />
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
                {/* NOT asChild — PostDeleteDialog renders a plain button that does
                    not forward props/ref (Story 10.4 upgrades it to a forwarding
                    AlertDialog); wrap it as a normal menu-item child instead. */}
                <DropdownMenuItem>
                  <PostDeleteDialog post={record} />
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      );
    },
  },
];

export function PostList({
  posts = [],
  emptyLabel = "No posts yet — create one.",
}: { posts?: PostRow[]; emptyLabel?: string }) {
  const [q, setQ] = useState("");
  const searching = q.trim().length > 0;

  // Client-driven read (AC5) — only meaningful while searching. When q is blank
  // the box is idle and we fall back to the server-rendered `posts`.
  const { data: searchData, loading: searchLoading } = useQuery<PostRow[]>(searchPosts, { q: q.trim() });

  const rows = searching ? searchData ?? [] : posts;

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
      {!searching && posts.length === 0 && <p className="text-sm text-muted-foreground">{emptyLabel}</p>}
      {searching && !searchLoading && rows.length === 0 && (
        <p className="text-sm text-muted-foreground">No posts match “{q.trim()}”.</p>
      )}

      {rows.length > 0 && <DataTable columns={columns} data={rows} />}
    </section>
  );
}
