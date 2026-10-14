// Story 19-0 — the new document read by the old bootstrap (SPIKE_OLD_CLIENT=1):
// what a browser gets when the server streams and the page's JavaScript is
// still the one 0.0.19 shipped. That bootstrap is a deferred module: it runs
// when the document ends and reads everything `__FLIGHT_DATA` holds by then.
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback, clicker } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("the old bootstrap shows the whole page once the document ends, and never the fallback", async ({ page, request }) => {
  await page.goto("/slow", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });

  // Nothing is mounted while the document is open.
  expect(await page.locator("#root").innerHTML()).toBe("");
  await expect(fallback(page, "A")).toHaveCount(0);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect(page.locator("#shell")).toHaveText("Slow");
  await clicker(page, "in-a").click();
  await expect(clicker(page, "in-a")).toHaveText("in-a: 1");
});
