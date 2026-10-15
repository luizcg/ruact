// Story 19-2 (AC12) — two requests at once each see their own; fast and slow
// boundaries on one page.
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const read = (page, id) =>
  page.locator(`#${id} li`).evaluateAll((items) => Object.fromEntries(items.map((li) => [li.dataset.k, li.textContent])));

test("AC12.1 — two pages at once, each block sees its own request", async ({ browser, request }) => {
  const first = await browser.newPage();
  const second = await browser.newPage();
  first.goto("/context?user=ada&locale=pt&zone=Tokyo&tenant=acme");
  second.goto("/context?user=bob&locale=en&zone=UTC&tenant=globex");
  await waitingAt(request, { a: 2 });
  // A request to an action that does not stream, in the middle.
  expect((await request.get("/plain")).status()).toBe(200);

  await open(request, "a");
  await expect(first.locator("#in-block")).toBeVisible();
  await expect(second.locator("#in-block")).toBeVisible();
  expect(await read(first, "in-block")).toMatchObject({
    current: '"ada"', locale: "pt", zone: "Tokyo", tenant: "acme", thread: "other thread",
  });
  expect(await read(second, "in-block")).toMatchObject({
    current: '"bob"', locale: "en", zone: "UTC", tenant: "globex", thread: "other thread",
  });
  await first.close();
  await second.close();
});

test("AC12.2 — fast, slow, fast: the first fast one comes with the shell, the second waits for the slow one", async ({ page, request }) => {
  await page.goto("/mixed", { waitUntil: "commit" });
  await waitingAt(request, { s: 1 });
  await expect(page.locator("#f1")).toHaveText("fast one");
  await expect(page.getByText("Loading slow…", { exact: true })).toBeVisible();
  await expect(page.getByText("Loading fast two…", { exact: true })).toBeVisible();
  await expect(page.locator("#f2")).toHaveCount(0);

  await open(request, "s");
  await expect(page.locator("#s")).toHaveText("open:s");
  await expect(page.locator("#f2")).toHaveText("fast two");
});
