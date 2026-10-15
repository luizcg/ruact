// Story 19-2 (AC22) — the document this gem streams, read by the bootstrap
// 0.0.19 shipped (`./run skew`: the assets built with that release's plugin,
// the server this checkout). What a browser gets in a deploy where the server
// is new and the page's JavaScript is still the old one.
//
// MEASURED, not required (results/skew-production.json). 19-0 measured it
// against the prototype, whose entry tag was still deferred: the old bootstrap
// ran when the document ended and showed the page whole. Since 19-1 the entry
// is `async`, so the old bootstrap runs early, reads the shell's rows only,
// and closes its stream.
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback, resultFile } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("AC22 — 0.0.19's bootstrap reads the streamed document", async ({ page, request }) => {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text().split("\n")[0]));
  page.on("pageerror", (error) => errors.push(error.message.split("\n")[0]));

  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await page.waitForFunction(() => document.getElementById("root")?.childElementCount > 0, null, { timeout: 5_000 })
    .catch(() => {});
  const whileOpen = { mounted: await page.locator("#shell").count() > 0, fallback: await fallback(page, "A").count() > 0 };

  await open(request, "a");
  await open(request, "b");
  await page.waitForFunction(() => document.readyState === "complete");
  // React's reveal throttle (300 ms), and a margin.
  await page.waitForTimeout(400);
  const text = async (selector) => ((await page.locator(selector).count()) ? page.locator(selector).textContent() : null);
  const atTheEnd = { a: await text("#a"), b: await text("#b"), fallback_still_shown: await fallback(page, "B").count() > 0 };
  fs.writeFileSync(resultFile("skew"), JSON.stringify({
    while_the_document_is_open: whileOpen, when_it_ends: atTheEnd, errors: [...new Set(errors)],
  }, null, 2) + "\n");
  expect(whileOpen.mounted).toBe(true);
});
