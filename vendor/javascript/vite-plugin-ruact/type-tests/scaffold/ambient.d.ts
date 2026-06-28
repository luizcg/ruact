// Story 10.2 (AC7 / Task 5) — AMBIENT stubs so the GENERATED `<Model>List.tsx`
// type-checks in ISOLATION, without a real shadcn install. The fixture
// `PostList.tsx` in this directory is byte-identical to the generator's live
// output (a gem rspec example asserts that equality), so type-checking it under
// `tsconfig.scaffold.json` proves the emitted typed List holds the FR99 server
// boundary + the shadcn `table`-primitive import contract. There is NO
// table-engine dependency — Story 10.2b moved the List off the `@tanstack/react-table`
// `DataTable` recipe onto the dep-free shadcn `table` primitive + a generated sort.
//
// These are deliberately MINIMAL structural shims — NOT the real shadcn / react
// types. Story 10.5 installs the real `@/components/ui/*` modules (incl. the
// `table` primitive); 10.7 wires the live end-to-end demo. The point here is the
// generated module's OWN type-safety (typed rows, sortable headers, the search
// accessor), not re-testing upstream libraries.

// JSX without `lib: ["dom"]` / `@types/react`: a permissive intrinsic-element
// table (every native prop is `any`, so `onChange={(e) => …}` etc. need no DOM
// event types). `jsx: "preserve"` in tsconfig.scaffold.json still type-checks
// every JSX expression against this namespace.
declare namespace JSX {
  interface Element {} // eslint-disable-line @typescript-eslint/no-empty-interface
  interface ElementClass {} // eslint-disable-line @typescript-eslint/no-empty-interface
  interface IntrinsicElements {
    [elem: string]: any;
  }
}

declare module "react" {
  export function useState<S>(initial: S | (() => S)): [S, (next: S | ((prev: S) => S)) => void];
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

  // Action accessors the generated Form imports (Story 10.3). Actions are NOT
  // typed by FR99 (only queries are — Story 13.4 decision A), so the accessors
  // take a loose payload and return `Promise<unknown>`; the Form narrows the
  // result with an `as { errors?: ... } | null` assertion at the call site.
  export const createPost: (payload: Record<string, unknown>) => Promise<unknown>;
  export const updatePost: (payload: Record<string, unknown>) => Promise<unknown>;
  // Story 10.4 — the destroy accessor the List's RowActions calls in `onConfirm`
  // (DELETE /posts/:id). Like the other actions it is not FR99-typed; it returns
  // `Promise<unknown>` and throws a `RuactActionError` on a non-2xx response.
  export const destroyPost: (payload: Record<string, unknown>) => Promise<unknown>;

  // Mirrors the runtime declaration (`ruact-server-functions-runtime/index.d.ts`)
  // — `reference` is the widened accessor shape (Story 13.4), `T` the return type.
  export function useQuery<T = unknown>(
    reference: (...args: never[]) => Promise<unknown>,
    params?: Record<string, unknown>,
  ): { data: T | undefined; loading: boolean; error: unknown };
}

// Story 10.2b — the shadcn `table` primitive (a styled HTML table; no engine).
// Permissive structural shims (like Button/Badge/DropdownMenu below): the
// generated List reads `row.<attr>` directly and drives its own `useState` sort,
// so there is nothing engine-typed left to check here. Story 10.5 installs the
// real module (`npx shadcn add table`).
declare module "@/components/ui/table" {
  type Props = { children?: any; [key: string]: any };
  export function Table(props: Props): any;
  export function TableHeader(props: Props): any;
  export function TableBody(props: Props): any;
  export function TableRow(props: Props): any;
  export function TableHead(props: Props): any;
  export function TableCell(props: Props): any;
}

declare module "@/components/ui/badge" {
  export function Badge(props: { children?: any; [key: string]: any }): any;
}

declare module "@/components/ui/button" {
  export function Button(props: { children?: any; [key: string]: any }): any;
}

declare module "@/components/ui/dropdown-menu" {
  type Props = { children?: any; [key: string]: any };
  export function DropdownMenu(props: Props): any;
  export function DropdownMenuTrigger(props: Props): any;
  export function DropdownMenuContent(props: Props): any;
  export function DropdownMenuItem(props: Props): any;
}

// Story 10.4 — the shadcn AlertDialog parts the generated `<Model>DeleteDialog`
// imports. The controlled `AlertDialog` types `open` + `onOpenChange` precisely
// (the controlled contract the generated dialog binds); the rest stay permissive
// structural shims (like Button/Badge above). Story 10.5 installs the real module.
declare module "@/components/ui/alert-dialog" {
  type Props = { children?: any; [key: string]: any };
  export function AlertDialog(props: {
    open?: boolean;
    onOpenChange?: (open: boolean) => void;
    [key: string]: any;
  }): any;
  export function AlertDialogTrigger(props: Props): any;
  export function AlertDialogContent(props: Props): any;
  export function AlertDialogHeader(props: Props): any;
  export function AlertDialogFooter(props: Props): any;
  export function AlertDialogTitle(props: Props): any;
  export function AlertDialogDescription(props: Props): any;
  export function AlertDialogCancel(props: Props): any;
  export function AlertDialogAction(props: Props): any;
}

// Story 10.3 — the shadcn Form primitives the generated `<Model>Form.tsx` imports.
// Permissive structural shims (like Button/Badge above): the point is the
// generated module's OWN type-safety (controlled state, the typed action
// accessors, the `initial` prop + `{ id; label }[]` options props), not
// re-testing upstream shadcn. Story 10.5 installs the real modules.
declare module "@/components/ui/label" {
  export function Label(props: { children?: any; [key: string]: any }): any;
}

// Input/Textarea/Switch/Select type the value + change handler precisely (the
// rest of the props stay permissive) so the isolated typecheck actually proves
// the generated Form binds STRING state to string controls and a boolean to the
// Switch — the controlled-state contract, not just import resolution.
declare module "@/components/ui/input" {
  export function Input(props: {
    value?: string;
    onChange?: (event: { target: { value: string } }) => void;
    [key: string]: any;
  }): any;
}

declare module "@/components/ui/textarea" {
  export function Textarea(props: {
    value?: string;
    onChange?: (event: { target: { value: string } }) => void;
    [key: string]: any;
  }): any;
}

declare module "@/components/ui/switch" {
  export function Switch(props: {
    checked?: boolean;
    onCheckedChange?: (checked: boolean) => void;
    [key: string]: any;
  }): any;
}

declare module "@/components/ui/select" {
  type Props = { children?: any; [key: string]: any };
  export function Select(props: {
    value?: string;
    onValueChange?: (value: string) => void;
    [key: string]: any;
  }): any;
  export function SelectContent(props: Props): any;
  export function SelectItem(props: Props): any;
  export function SelectTrigger(props: Props): any;
  export function SelectValue(props: Props): any;
}
