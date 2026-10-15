// Story 19-2 (AC9) — a <Suspense> inside a `cache` block, read back from the
// cache: its marker belongs to the render that wrote it. That boundary gets an
// error; the other one shows its own content, once.
import { test, expect } from "@playwright/test";
import { ENV, reset, waitingAt, open, events } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("AC9 — a <Suspense> read from the cache errors alone, never with another boundary's content", async ({ page }) => {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text()));

  await page.goto("/cached?visit=1");
  await expect(page.locator("#cached")).toHaveText("written on visit 1");
  await expect(page.locator("#other")).toHaveText("the other boundary");

  await page.goto("/cached?visit=2");
  await expect(page.locator("#other")).toHaveText("the other boundary");
  await expect(page.locator("#other")).toHaveCount(1);
  await expect(page.locator("#cached")).toHaveCount(0);
  await expect(page.getByText("Loading cached…", { exact: true })).toBeVisible();
  if (ENV === "development") {
    await expect(page.locator("#ruact-dev-overlay [data-overlay-message]")).toContainText("inside `cache`");
  } else {
    await expect.poll(() => errors.join("\n")).toContain("[ruact] Server error: An error occurred in a <Suspense>");
  }
});

// Story 19-2 (AC9.2) — a `cache` inside a <Suspense>: the fragment is written
// when the block runs, and read when it runs again — still after the shell.
test("AC9.2 — a cache inside a <Suspense>: written when the block runs, read on the next load, still deferred", async ({ page, request }) => {
  page.goto("/cache_inside", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(page.getByText("Loading inside…", { exact: true })).toBeVisible();
  await open(request, "a");
  await expect(page.locator("#inside")).toHaveText("open:a");

  // Warm: the block runs again, after the shell, and reads the fragment.
  const body = await (await request.get("/cache_inside")).text();
  expect(body).toContain(".streaming=true");
  expect(body.indexOf("open:a")).toBeGreaterThan(body.indexOf(".streaming=true"));
  await page.goto("/cache_inside");
  await expect(page.locator("#inside")).toHaveText("open:a");
  const seen = await events(request);
  expect(seen.filter((event) => event === "block_start:inside")).toHaveLength(3);
  expect(seen.filter((event) => event === "cache_miss")).toHaveLength(1);
});
