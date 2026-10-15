// Story 19-2 (AC8) — where a <Suspense> sits in the template: inside a client
// component's children, in an `each` loop.
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

for (const how of ["first load", "navigation"]) {
  test(`AC8.1/8.2 — inside a component's children and in a loop (${how})`, async ({ page, request }) => {
    if (how === "navigation") {
      await page.goto("/");
      await page.click("#to-inside");
    } else {
      page.goto("/inside");
    }
    await waitingAt(request, { a: 1 });

    // Inside the component: its fallback is in it, and the component keeps
    // its state while the boundary resolves.
    const box = page.locator("[data-box]");
    await expect(box.getByText("Loading A…", { exact: true })).toBeVisible();
    await page.click("[data-box-count]");
    await expect(page.locator("[data-box-count]")).toHaveText("box: 1");
    await open(request, "a");
    await expect(box.locator("#a")).toHaveText("open:a");
    await expect(page.locator("[data-box-count]")).toHaveText("box: 1");

    // In a loop: one block per item, in page order — the second item's gate
    // opened first changes nothing until the first item's opens.
    await waitingAt(request, { x: 1 });
    await open(request, "y");
    await expect(page.locator('[data-loop="y"]')).toHaveCount(0);
    await open(request, "x");
    await expect(page.locator('[data-loop="x"]')).toHaveText("open:x");
    await expect(page.locator('[data-loop="y"]')).toHaveText("open:y");
    await expect(page.getByText("Loading an item…", { exact: true })).toHaveCount(0);
  });
}
