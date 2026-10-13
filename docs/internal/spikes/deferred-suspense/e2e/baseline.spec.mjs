// Story 19-0, AC1 — ruact as released (0.0.19), with ActionController::Live in
// the controller: today's best case. While the gate is closed nothing reaches
// the browser, on a first load and on a navigation, because the whole template
// (the content of <Suspense> included) is evaluated before the first byte.
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("first load: no response while the gate is closed", async ({ page, request }) => {
  let committed = false;
  const response = page.goto("/slow", { waitUntil: "commit" }).then((r) => ((committed = true), r));
  await waitingAt(request, { a: 1 });

  // The server is inside `render_to_string`, blocked at the gate.
  expect(committed).toBe(false);
  expect(page.url()).toBe("about:blank");

  await open(request, "a");
  await response;
  await expect(page.locator("#a")).toHaveText("open:a");
});

test("navigation: the old page stays, with no fallback, while the gate is closed", async ({ page, request }) => {
  await page.goto("/");
  await expect(page.locator("#home")).toBeVisible();

  await page.click("#to-slow");
  await waitingAt(request, { a: 1 });

  await expect(page.locator("#home")).toBeVisible();
  await expect(page.locator("#shell")).toHaveCount(0);
  await expect(fallback(page, "A")).toHaveCount(0);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
});
