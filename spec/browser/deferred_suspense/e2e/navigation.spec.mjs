// Story 19-2 (AC1–AC4) — navigating while a boundary is pending: the page that
// is left, and the server that was rendering it.
//
// The server's side is read from /__state: which blocks started, what ruact
// logged ("the client left"), and the pool. Nothing waits by time.
//
// What the server does with a request whose fetch the router aborted is
// MEASURED, not required: Chrome sometimes keeps reading an aborted response
// to reuse its connection, and the server, which only sees a closed
// connection, then renders the next block. Which one happened is written to
// results/navigation-<env>.json, and added to
// results/navigation-<env>.history.jsonl. A document the router leaves is stopped, and
// that one is required (AC3).
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { state, events, waitingAt, open, reset, fallback, clicker, resultFile } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const clientLeft = async (request) => (await events(request)).filter((event) => event.includes("the client left"));
const count = (list, item) => list.filter((event) => event === item).length;

// The last run's outcomes, and every run's, one line each: an outcome seen
// once stays on record when the next run does not see it.
const outcomes = {};
test.afterAll(() => {
  const file = resultFile("navigation");
  fs.writeFileSync(file, JSON.stringify(outcomes, null, 2) + "\n");
  fs.appendFileSync(file.replace(/\.json$/, ".history.jsonl"), JSON.stringify({ at: new Date().toISOString(), ...outcomes }) + "\n");
});

// What the server did with the request the router aborted, once its first
// block could end: it saw the client leave, or it went on to the next block.
async function abortedRequestOutcome(request, startsOfB) {
  await expect
    .poll(async () => (await clientLeft(request)).length > 0 || count(await events(request), "block_start:b") >= startsOfB)
    .toBe(true);
  return (await clientLeft(request)).length > 0 ? "stopped: the client left" : "rendered its next block";
}

// What a page left behind must not do: report an error.
function watchErrors(page) {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text()));
  return errors;
}

async function expectLeftCleanly(request) {
  await expect.poll(() => clientLeft(request)).toEqual([
    expect.stringContaining("PagesController#two: the client left; 1 <Suspense> boundary was not rendered"),
  ]);
  expect(await events(request)).not.toContain("block_start:b");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
}

test("AC1 — a navigation that replaces one still pending: the new page, and the server stops", async ({ page, request }) => {
  const errors = watchErrors(page);
  await page.goto("/");
  await page.click("#to-two");
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();

  await page.click("#to-plain");
  await expect(page).toHaveURL(/\/plain$/);
  await expect(page.locator("#shell")).toHaveText("Plain");
  await expect(fallback(page, "A")).toHaveCount(0);

  await open(request, "a");
  outcomes.AC1 = await abortedRequestOutcome(request, 1);
  await expect(page.locator("#a")).toHaveCount(0);
  await expect(page.locator("#b")).toHaveCount(0);
  await expect(page.locator("#shell")).toHaveText("Plain");
  await expect(page.locator("#ruact-dev-overlay")).toHaveCount(0);
  expect(errors.join("\n")).not.toContain("[ruact] Server error");
  // Whichever way the server went, nothing is left holding a connection.
  await open(request, "b");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});

test("AC2 — the same page twice: the first request is cut, the second renders once", async ({ page, request }) => {
  await page.goto("/");
  await page.click("#to-two");
  await waitingAt(request, { a: 1 });

  await page.click("#to-two-again");
  await waitingAt(request, { a: 2 });

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  outcomes.AC2 = await abortedRequestOutcome(request, 2);
  await expect(page.locator("#a")).toHaveCount(1);

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect(page.locator("#b")).toHaveCount(1);
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
  // When the server saw the first request's client leave, only the second
  // rendered its next block.
  if (outcomes.AC2.startsWith("stopped")) expect(count(await events(request), "block_start:b")).toBe(1);
});

test("AC2.3 — the same page again from the first load, while its document is open", async ({ page, request }) => {
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();

  await page.click("#to-two-again");
  await waitingAt(request, { a: 2 });

  // The document the router left is stopped (AC3): its request ends.
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect.poll(() => clientLeft(request)).toHaveLength(1);
  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
  expect(count(await events(request), "block_start:b")).toBe(1);
});

test("AC3 — a click while the document is still open: the new page works, the old document stops", async ({ page, request }) => {
  const errors = watchErrors(page);
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();

  await page.click("#to-plain");
  await expect(page).toHaveURL(/\/plain$/);
  await clicker(page, "plain").click();
  await expect(clicker(page, "plain")).toHaveText("plain: 1");

  await open(request, "a");
  await expectLeftCleanly(request);
  await expect(page.locator("#shell")).toHaveText("Plain");
  await expect(page.locator("#a")).toHaveCount(0);
  await expect(clicker(page, "plain")).toHaveText("plain: 1");
  expect(errors.join("\n")).not.toContain("[ruact] Server error");
});

test("AC4.2 — revalidate() while a navigation's boundary is pending resolves after the last row", async ({ page, request }) => {
  await page.goto("/");
  await page.click("#to-two");
  await waitingAt(request, { a: 1 });

  await page.click("#revalidate");
  await expect(page.locator("#revalidate")).toHaveAttribute("data-state", "pending");
  await waitingAt(request, { a: 2 });

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  outcomes["AC4.2"] = await abortedRequestOutcome(request, 2);
  await expect(page.locator("#revalidate")).toHaveAttribute("data-state", "pending");

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect(page.locator("#b")).toHaveCount(1);
  await expect(page.locator("#revalidate")).toHaveAttribute("data-state", "resolved");
});

test("AC4.3 — revalidate() while the first load's document is open", async ({ page, request }) => {
  const errors = watchErrors(page);
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });

  await page.click("#revalidate");
  await waitingAt(request, { a: 2 });
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect(page.locator("#revalidate")).toHaveAttribute("data-state", "resolved");
  expect(count(await events(request), "block_start:b")).toBe(1);
  expect(errors.join("\n")).not.toContain("[ruact] Server error");
});

test("AC4.4 — a boundary that failed shows its new content after revalidate()", async ({ page }) => {
  await page.goto("/flaky");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#a")).toHaveCount(0);
  if (process.env.RAILS_ENV !== "production") await page.locator("#ruact-dev-overlay").click();

  await page.click("#revalidate");
  await expect(page.locator("#revalidate")).toHaveAttribute("data-state", "resolved");
  await expect(page.locator("#a")).toHaveText("second time");
  await expect(fallback(page, "A")).toHaveCount(0);
});
