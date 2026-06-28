"use client";

// Post delete confirmation — a CONTROLLED shadcn AlertDialog. The
// PARENT owns `open` and provides `onConfirm`; this component owns only its local
// submit/error state. `onConfirm` performs the destroyPost call (DELETE
// /posts/:id) and reports `{ ok, error? }`:
//
//   - on success the parent closes the dialog (in-list removal of the row, or the
//     server-driven `$redirect` the runtime follows) — no URL is built here;
//   - on failure the dialog STAYS OPEN and shows the message inline (the gem's
//     structured-error shape: the exception message in development, the generic
//     server message in production).
//
// There is no Rails `method=delete` fallback — the destroyPost action
// is the only path. Cancel / Escape / outside-click close via `onOpenChange(false)`
// without deleting; focus returns to the row's Delete trigger (Radix default —
// the trigger is never unmounted while the dialog animates).
import { useState } from "react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_at: string | null; author_id: number | null };

// FR100 — opt-in call-site contract. INERT for this component: it is rendered
// only from PostList.tsx (JSX), never from an ERB `<Component>` tag,
// so the 13.5 preprocess validator never runs against it. Retained for uniformity
// with the List/Form.
export const __ruactContract = {
  props: { post: "required" },
};

export function PostDeleteDialog({
  open,
  onOpenChange,
  post,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  post: PostRow;
  onConfirm: () => Promise<{ ok: boolean; error?: string }>;
}) {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConfirm(event: { preventDefault: () => void }) {
    // Keep the dialog open across the async destroy — Radix's AlertDialogAction
    // would otherwise close it on click. The PARENT closes it (via onOpenChange)
    // only after a successful delete; a failure leaves it open with the message.
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    const res = await onConfirm();
    setSubmitting(false);
    if (!res.ok) {
      setError(res.error ?? "Could not delete this post");
    }
  }

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Delete “{String(post.title ?? "")}”?</AlertDialogTitle>
          <AlertDialogDescription>This action cannot be undone.</AlertDialogDescription>
        </AlertDialogHeader>
        {error && <p className="text-sm text-destructive">{error}</p>}
        <AlertDialogFooter>
          {/* Cancel gets default focus (Radix) — the safe choice is the default. */}
          <AlertDialogCancel disabled={submitting}>Cancel</AlertDialogCancel>
          <AlertDialogAction
            onClick={handleConfirm}
            disabled={submitting}
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
          >
            {submitting ? "Deleting…" : "Delete"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
