// Story 14.4 (AC5) — AMBIENT stubs so the GENERATED design-system-AGNOSTIC
// `<Model>List.tsx` / `<Model>Form.tsx` / `<Model>DeleteDialog.tsx` type-check in
// ISOLATION. The fixtures in this directory are byte-identical to the generator's
// live agnostic output (a gem rspec example asserts that equality), so
// type-checking them under `tsconfig.scaffold-agnostic.json` proves the emitted
// typed components hold the FR99 server boundary with NO design-system dependency.
//
// The POINT of this stub is the opposite of the shadcn one (`../ambient.d.ts`):
// it declares ONLY React + `@/.ruact/server-functions` and deliberately NO
// `@/components/ui/*` module. So a stray shadcn import in an agnostic template
// would fail to resolve here and turn the `npm run typecheck` job RED — that
// unresolved-module failure is the AC5 proof that the agnostic default needs
// zero `@/components/ui` resolution.

// JSX without `lib: ["dom"]` / `@types/react`: a permissive intrinsic-element
// table (every native prop is `any`, so `onChange={(e) => …}` etc. need no DOM
// event types). `jsx: "preserve"` in the tsconfig still type-checks every JSX
// expression against this namespace.
declare namespace JSX {
  interface Element {} // eslint-disable-line @typescript-eslint/no-empty-interface
  interface ElementClass {} // eslint-disable-line @typescript-eslint/no-empty-interface
  interface IntrinsicElements {
    [elem: string]: any;
  }
}

// The generated DeleteDialog types its <dialog> ref as `HTMLDialogElement` — the
// SAME type a real app's `lib: ["dom"]` gives `<dialog ref={…}>` (so the emitted
// .tsx type-checks end-to-end in the user's typed app, FR99). This isolated
// harness has no `lib: dom`, so we declare the minimal structural members the
// generated code touches (`open` / `showModal` / `close`). In a real app this
// merges with lib.dom's full HTMLDialogElement.
interface HTMLDialogElement {
  open: boolean;
  showModal(): void;
  close(): void;
}

declare module "react" {
  export function useState<S>(initial: S | (() => S)): [S, (next: S | ((prev: S) => S)) => void];
  // The generated DeleteDialog drives the native <dialog> off a ref + an effect.
  export function useRef<T>(initial: T): { current: T };
  export function useEffect(effect: () => void | (() => void), deps?: ReadonlyArray<unknown>): void;
  // The generated Form's `handleSubmit(event: FormEvent)` only calls
  // `event.preventDefault()`; a minimal shim keeps the type load-bearing without
  // pulling in `@types/react`.
  export interface FormEvent {
    preventDefault(): void;
  }
}

declare module "@/.ruact/server-functions" {
  // FR88/FR99 wire union — the only param value type a query accessor accepts.
  type Wire = string | number | boolean | null;

  // The codegen exports a generic `search` from `<Plural>Query#search(q:)`,
  // typed from the declared `(q:)` kwarg (Story 13.4). The List aliases it
  // `search<Plural>`.
  export const search: (params: { q: Wire }) => Promise<unknown>;

  // Action accessors the generated Form imports. Actions are NOT typed by FR99
  // (only queries are — Story 13.4 decision A), so the accessors take a loose
  // payload and return `Promise<unknown>`; the Form narrows the result with an
  // `as { errors?: ... } | null` assertion at the call site.
  export const createPost: (payload: Record<string, unknown>) => Promise<unknown>;
  export const updatePost: (payload: Record<string, unknown>) => Promise<unknown>;
  // The destroy accessor the List's RowActions calls in `onConfirm` (DELETE
  // /posts/:id). Like the other actions it is not FR99-typed; it returns
  // `Promise<unknown>` and throws a `RuactActionError` on a non-2xx response.
  export const destroyPost: (payload: Record<string, unknown>) => Promise<unknown>;

  // Mirrors the runtime declaration (`ruact-server-functions-runtime/index.d.ts`)
  // — `reference` is the widened accessor shape (Story 13.4), `T` the return type.
  export function useQuery<T = unknown>(
    reference: (...args: never[]) => Promise<unknown>,
    params?: Record<string, unknown>,
  ): { data: T | undefined; loading: boolean; error: unknown };
}
