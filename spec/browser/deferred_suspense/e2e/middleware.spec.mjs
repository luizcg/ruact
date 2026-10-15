// Story 19-2 (AC17) — what a block sees of a scope a MIDDLEWARE set around the
// app: a locale, a tenant kept in Rails' execution state, a database role with
// prevent_writes (what Rails' DatabaseSelector does with connected_to). The
// middleware's block ends when the response starts, before a <Suspense> runs.
// Measured (results/middleware-<env>.json): the database role is gone; the
// tenant is still there, copied to the action's thread when it started. The
// locale is not to be relied on: with i18n before 1.15 the block loses it, and
// with 1.15 even the shell showed another value once the pool's threads had
// served other requests (ADR D3) — so it is recorded, not asserted. The fix for
// all of them is to scope in the controller (around_action), proved by "what a
// deferred block sees".
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, resultFile } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const read = (page, id) =>
  page.locator(`#${id} li`).evaluateAll((items) => Object.fromEntries(items.map((li) => [li.dataset.k, li.textContent])));

test("AC17 — a middleware's scope holds for the shell and is gone for a block that runs later", async ({ page, request }) => {
  page.goto("/context_mw", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  // The shell in the browser: the middleware stack has returned, so its scope
  // has ended before the block runs.
  await expect(page.locator("#in-shell")).toBeVisible();
  await open(request, "a");
  await expect(page.locator("#in-block")).toBeVisible();
  const shell = await read(page, "in-shell");
  const block = await read(page, "in-block");
  const i18n = (await (await request.get("/__state")).json()).i18n ?? null;
  fs.writeFileSync(resultFile("middleware"), JSON.stringify({ i18n, shell, block }, null, 2) + "\n");

  expect(shell).toMatchObject({ tenant: "from a middleware", role: "writing", prevent_writes: "true" });
  // The database role the middleware set ended with its block.
  expect(block.prevent_writes).toBe("false");
  // The tenant is copied to the action's thread when it started.
  expect(block).toMatchObject({ tenant: "from a middleware", thread: "other thread" });
});

// Story 19-2 (AC17.1) — Rails' DatabaseSelector (primary + replica): the role
// a GET reads from, in the shell and in a block that runs later; then with the
// role set in the controller, the fix the guide gives.
const roles = {};
test.afterAll(() => fs.writeFileSync(resultFile("database-selector"), JSON.stringify(roles, null, 2) + "\n"));

// The selector's connected_to ends with the middleware's block, when the
// response starts: the block runs as a writer. Set in the controller, the role
// holds for the block too.
const expected = { selector: { shell: "reading", block: "writing" }, controller: { shell: "reading", block: "reading" } };

for (const [path, name] of [["/role", "selector"], ["/role_fixed", "controller"]]) {
  test(`AC17.1 — the database role, chosen by the ${name}`, async ({ page, request }) => {
    page.goto(path, { waitUntil: "commit" });
    await waitingAt(request, { a: 1 });
    await expect(page.locator("#shell-role")).toBeVisible();
    await open(request, "a");
    await expect(page.locator("#block-role")).toBeVisible();
    roles[name] = { shell: await page.locator("#shell-role").textContent(), block: await page.locator("#block-role").textContent() };
    expect(roles[name]).toEqual(expected[name]);
  });
}
