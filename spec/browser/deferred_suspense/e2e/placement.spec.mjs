// Story 19-2 (AC8) — where a <Suspense> sits in the template: inside a client
// component's children, in an `each` loop, in a partial and a collection.
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

// AC8.4 — a partial with a local, and `render collection:`: each block shows
// its own item, in page order, with the partial's own `t(".label")`.
for (const how of ["first load", "navigation"]) {
  test(`AC8.4 — in a partial and in a collection (${how})`, async ({ page, request }) => {
    if (how === "navigation") {
      await page.goto("/");
      await page.evaluate(() => {
        const a = Object.assign(document.createElement("a"), { id: "to-partials", href: "/partials", textContent: "partials" });
        document.body.append(a);
      });
      await page.click("#to-partials");
    } else {
      page.goto("/partials");
    }
    await waitingAt(request, { p1: 1 });
    await expect(page.getByText("Loading a partial…", { exact: true })).toHaveCount(3);
    await open(request, "p1");
    await expect(page.locator('[data-partial="p1"]')).toHaveText("open:p1 (the partial's label)");

    // The second item's gate first: its block has not started (page order).
    await waitingAt(request, { c1: 1 });
    await open(request, "c2");
    await waitingAt(request, { c1: 1 });
    await open(request, "c1");
    await expect(page.locator('[data-partial="c1"]')).toHaveText("open:c1 (the partial's label)");
    await expect(page.locator('[data-partial="c2"]')).toHaveText("open:c2 (the partial's label)");
  });
}
