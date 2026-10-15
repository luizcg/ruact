// Story 19-2 (AC3.3) — what the router stopping a document it leaves does to
// what that document was still loading: an image of the layout (outside
// #root, so the new page keeps it), a fetch, a module import(). Each is held
// at a gate of its own while the router leaves the page, then let go.
//
// MEASURED, not required: written to results/leaving-<env>.json, and read by
// the decision to stop the document (ADR, Story 19-2 Resultado).
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, resultFile } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const outcomes = {};
test.afterAll(() => {
  const file = resultFile("leaving");
  fs.writeFileSync(file, JSON.stringify(outcomes, null, 2) + "\n");
});

test("AC3.3 — an image, a fetch and an import() still loading when the router leaves a streaming document", async ({ page, request }) => {
  await page.goto("/two?img=1", { waitUntil: "commit" });
  await waitingAt(request, { a: 1, img: 1 });
  await page.waitForFunction(() => window.__ruact_revalidate);
  await page.evaluate(() => {
    const settle = (promise) => promise.then((value) => `ok:${value}`, (error) => `failed:${error.name}: ${error.message}`);
    window.__held = {
      fetch: settle(fetch("/__held/fetch").then((response) => response.text())),
      import: settle(import("/__held/module.js").then((module) => module.value)),
    };
  });
  await waitingAt(request, { a: 1, img: 1, fetch: 1, module: 1 });

  await page.click("#to-plain");
  await expect(page).toHaveURL(/\/plain$/);
  for (const gate of ["img", "fetch", "module", "a"]) await open(request, gate);

  const held = await page.evaluate(async () => ({ fetch: await window.__held.fetch, import: await window.__held.import }));
  await page.waitForFunction(() => document.getElementById("logo")?.complete);
  const image = await page.evaluate(() => {
    const logo = document.getElementById("logo");
    return logo.naturalWidth > 0 ? "loaded" : "broken";
  });
  // The same module again, from the page the router opened: a module whose
  // fetch failed stays failed for the document in some browsers.
  const again = await page.evaluate(() =>
    import("/__held/module.js").then((module) => `ok:${module.value}`, (error) => `failed:${error.name}: ${error.message}`));
  outcomes["AC3.3"] = { image, fetch: held.fetch, import: held.import, import_again: again };
  await expect(page.locator("#shell")).toHaveText("Plain");
});
