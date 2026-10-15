// Story 19-2 (AC17) — what a block sees of a scope a MIDDLEWARE set around the
// app: a locale, a tenant kept in Rails' execution state, a database role with
// prevent_writes (what Rails' DatabaseSelector does with connected_to). The
// middleware's block ends when the response starts, before a <Suspense> runs.
// Measured (results/middleware-<env>.json): the database role is gone; the
// locale and the tenant are still there, copied to the action's thread when
// it started (one request at a time — the locale of a pool thread another
// request left is ADR D3's case). The fix for all of them is to scope in the
// controller (around_action), proved by "what a deferred block sees".
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { ENV, waitingAt, open, reset } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const read = (page, id) =>
  page.locator(`#${id} li`).evaluateAll((items) => Object.fromEntries(items.map((li) => [li.dataset.k, li.textContent])));

test("AC17 — a middleware's scope holds for the shell and is gone for a block that runs later", async ({ page, request }) => {
  page.goto("/context_mw", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#in-block")).toBeVisible();
  const shell = await read(page, "in-shell");
  const block = await read(page, "in-block");
  const i18n = (await (await request.get("/__state")).json()).i18n ?? null;
  fs.writeFileSync(`results/middleware-${ENV}.json`, JSON.stringify({ i18n, shell, block }, null, 2) + "\n");

  expect(shell).toMatchObject({ locale: "pt", tenant: "from a middleware", role: "writing", prevent_writes: "true" });
  // The database role the middleware set ended with its block.
  expect(block.prevent_writes).toBe("false");
  // The tenant is copied to the action's thread when it started. The locale
  // too since i18n 1.15, which keeps it in Rails' execution state; before,
  // in a thread variable, which is not copied (./run i18n 1.14.7).
  const [major, minor] = i18n.split(".").map(Number);
  const keepsLocale = major > 1 || (major === 1 && minor >= 15);
  expect(block).toMatchObject({ locale: keepsLocale ? "pt" : "en", tenant: "from a middleware", thread: "other thread" });
});
