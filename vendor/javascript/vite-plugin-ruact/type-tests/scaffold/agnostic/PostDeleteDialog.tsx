"use client";

// Post delete confirmation — a CONTROLLED, DESIGN-SYSTEM-AGNOSTIC
// dialog (Story 14.4 / FR103) built on the native HTML <dialog> element — NO
// shadcn/ui, NO Radix, NO Tailwind. The PARENT owns `open` and provides
// `onConfirm`; this component owns only its local submit/error state and drives
// the native modal off the `open` prop (`showModal()`/`close()`). `onConfirm`
// performs the destroyPost call (DELETE /posts/:id) and reports `{ ok, error? }`:
//
//   - on success the parent closes the dialog (in-list removal of the row, or the
//     server-driven `$redirect` the runtime follows) — no URL is built here;
//   - on failure the dialog STAYS OPEN and shows the message inline (the gem's
//     structured-error shape: the exception message in development, the generic
//     server message in production).
//
// There is no Rails `method=delete` fallback — the destroyPost action is the
// only path. Cancel closes via `onOpenChange(false)`; Escape fires the native
// `close` event, which we forward to `onOpenChange(false)` to keep the parent
// state in sync. (The shadcn AlertDialog styling is the opt-in `--shadcn` path —
// Story 14.5.)
import { useEffect, useRef, useState } from "react";

type PostRow = { id: number; title: string | null; body: string | null; published: boolean | null; views: number | null; published_on: string | null; published_at: string | null; author_id: number | null };

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
  const dialogRef = useRef<HTMLDialogElement | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Drive the native <dialog> modal state off the controlled `open` prop.
  useEffect(() => {
    const node = dialogRef.current;
    if (!node) return;
    if (open && !node.open) node.showModal();
    if (!open && node.open) node.close();
  }, [open]);

  async function handleConfirm(event: { preventDefault: () => void }) {
    // The PARENT closes the dialog (via onOpenChange) only after a successful
    // delete; a failure leaves it open with the message.
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
    <dialog ref={dialogRef} onClose={() => onOpenChange(false)}>
      <h2>Delete “{String(post.title ?? "")}”?</h2>
      <p>This action cannot be undone.</p>
      {error && <p>{error}</p>}
      <p>
        <button type="button" onClick={() => onOpenChange(false)} disabled={submitting}>
          Cancel
        </button>
        {" "}
        <button type="button" onClick={handleConfirm} disabled={submitting}>
          {submitting ? "Deleting…" : "Delete"}
        </button>
      </p>
    </dialog>
  );
}
