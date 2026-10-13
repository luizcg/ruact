// Story 19-0, AC3 — the proof. With the gate closed the browser shows the
// shell and the fallback; opening the gate puts the content in their place,
// in the same document. On a first load and on a navigation.
//
// Nothing here waits by time: the test learns from /__state that the server is
// blocked at the gate, looks at the page, and opens the gate itself.
//
// Against ruact as released (SPIKE_MODE=baseline) both tests fail: see
// baseline.spec.mjs for what happens there instead.
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, documentOf, fallback, clicker } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("first load: shell and fallback while the gate is closed, the content when it opens", async ({ page, request }) => {
  const loaded = page.goto("/slow"); // resolves on `load`: after the last row
  await waitingAt(request, { a: 1 });

  await expect(page.locator("#shell")).toHaveText("Slow");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#after")).toHaveText("after the boundary");
  await expect(page.locator("#a")).toHaveCount(0);

  // The page is alive while it waits: an island in the shell takes a click.
  await clicker(page, "shell").click();
  await expect(clicker(page, "shell")).toHaveText("shell: 1");
  const doc = await documentOf(page);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect(fallback(page, "A")).toHaveCount(0);
  await loaded;

  // Same document, and the island kept its state; the one that arrived works.
  expect(await documentOf(page)).toBe(doc);
  await expect(clicker(page, "shell")).toHaveText("shell: 1");
  await clicker(page, "in-a").click();
  await expect(clicker(page, "in-a")).toHaveText("in-a: 1");
});

test("navigation: shell and fallback while the gate is closed, the content when it opens", async ({ page, request }) => {
  await page.goto("/");
  await expect(page.locator("#home")).toBeVisible();
  const doc = await documentOf(page);

  await page.click("#to-slow");
  await waitingAt(request, { a: 1 });

  await expect(page).toHaveURL(/\/slow$/);
  await expect(page.locator("#shell")).toHaveText("Slow");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#a")).toHaveCount(0);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect(fallback(page, "A")).toHaveCount(0);
  expect(await documentOf(page)).toBe(doc);
});
