// Story 19-0 — what the prototype does past the happy path (AC4, AC5), and what
// a deferred block can still see of the request (decision D3). Each test is a
// measurement: where the two delivery mechanisms differ, the expectation says so.
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { MODE, ENV, state, waitingAt, open, reset, fallback, clicker } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const events = async (request) => (await state(request)).events;

test("the page mounts before the document ends", async ({ page, request }) => {
  await page.goto("/slow", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  expect(await page.evaluate(() => document.readyState)).toBe("loading");
  expect(await page.evaluate(() => globalThis.__SPIKE_MOUNTED_WHILE_LOADING)).toBe(true);
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
});

// AC4. Blocks run one at a time, in the order the page has them.
test("two boundaries: opening the second gate first changes nothing until the first opens", async ({ page, request }) => {
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "b");
  // B's block has not started: nobody is at gate b, and nothing new was written.
  expect(await events(request)).toEqual(["shell_written", "block_start:0"]);
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect
    .poll(() => events(request))
    .toEqual(["shell_written", "block_start:0", "block_end:0", "block_start:1", "block_end:1", "complete"]);
});

test("a boundary inside a boundary: the inner one is found when the outer block runs", async ({ page, request }) => {
  await page.goto("/nested", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  await expect(fallback(page, "B")).toHaveCount(0);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await waitingAt(request, { b: 1 });
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
});

// AC5 (b). The response is already 200: the error goes to the boundary.
test("a block that raises: its boundary keeps the fallback, the next block still runs", async ({ page, request }) => {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text()));

  const response = await page.goto("/error", { waitUntil: "commit" });
  expect(response.status()).toBe(200);
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible(); // mounted: the error arrives later
  await open(request, "a");

  await waitingAt(request, { b: 1 });
  expect(await events(request)).toContain("block_error:NoMethodError");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#a")).toHaveCount(0);

  if (ENV === "development") {
    // Luiz's question: development can put the error over the page.
    const overlay = page.locator("#ruact-dev-overlay");
    await expect(overlay).toBeVisible();
    await expect(overlay.locator("[data-overlay-message]")).toContainText("NoMethodError");
    await expect(overlay.locator("[data-overlay-message]")).toContainText("total");
    await page.screenshot({ path: `results/overlay-${MODE}.png` });
    await overlay.click();
    await expect(overlay).toHaveCount(0);
  } else {
    await expect(page.locator("#ruact-dev-overlay")).toHaveCount(0);
    // Production says that it failed, and nothing about why.
    await expect.poll(() => errors.join("\n")).toContain("[ruact] Server error");
    expect(errors.join("\n")).not.toContain("NoMethodError");
  }

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
});

// The same error, already in the stream when React mounts: caught in the first
// commit, before any effect has run.
test("a block that had already raised when the page mounts", async ({ page, request }) => {
  test.skip(ENV !== "development", "the overlay is development only");
  await open(request, "a");
  await open(request, "b");
  await page.goto("/error");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#ruact-dev-overlay [data-overlay-message]")).toContainText("NoMethodError");
});

// D3. What the block sees of what the request set up.
test("what a deferred block sees of the request", async ({ page, request }) => {
  await page.goto("/context", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#in-block")).toBeVisible();

  const read = (id) =>
    page.locator(`#${id} li`).evaluateAll((items) => Object.fromEntries(items.map((li) => [li.dataset.k, li.textContent])));
  const shell = await read("in-shell");
  const block = await read("in-block");
  const lazy = { shell: await page.locator("#shell-lazy").textContent(), block: await page.locator("#block-lazy").textContent() };
  const order = await events(request);
  fs.writeFileSync(`results/context-${MODE}-${ENV}.json`, JSON.stringify({ shell, block, lazy, events: order }, null, 2) + "\n");

  // The same in both mechanisms: the view, its template path, CurrentAttributes.
  expect(shell).toMatchObject({ locale: "pt", t: "olá", zone: "Tokyo", tenant: "acme", current: '"ada"' });
  expect(lazy).toEqual({ shell: "lazy lookup (pt)", block: MODE === "live" ? "lazy lookup (pt)" : "lazy lookup (en)" });
  expect(block.current).toBe('"ada"');

  if (MODE === "live") {
    // The action is still running: its around_action is on the stack.
    expect(block).toMatchObject({ locale: "pt", t: "olá", zone: "Tokyo", tenant: "acme", thread: "other thread" });
    expect(order.indexOf("after_action")).toBeGreaterThan(order.indexOf("block_end:0"));
  } else {
    // The action returned before the block ran: what around_action scoped is gone.
    expect(block).toMatchObject({ locale: "en", t: "hello", zone: "UTC", tenant: "(none)", thread: "request thread" });
    expect(order.indexOf("after_action")).toBeLessThan(order.indexOf("block_start:0"));
  }
});

// D5. Headers leave with the first byte.
test("a cookie or session write inside a block does not reach the browser", async ({ page, request }) => {
  await page.goto("/late_cookie", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("cookie written");

  const names = (await page.context().cookies()).map((cookie) => cookie.name);
  expect(names).toContain("early");
  expect(names).not.toContain("late");
  expect(await (await page.request.get("/__session")).json()).toMatchObject({ late: null });
});

// A lazy relation is loaded where the view walks it: inside the block.
test("a slow query inside a block holds one connection while it runs, and gives it back", async ({ page, request }) => {
  await page.goto("/db", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  expect((await state(request)).pool.busy).toBe(1);

  await open(request, "a");
  await expect(page.locator("#a li")).toHaveText(["one", "two"]);
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});
