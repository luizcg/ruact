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
//
// Story 19-3 — DETECTED, and required: ruact logs once that the page's
// JavaScript was built by another ruact (0.0.19's records no version), the
// doctor's manifest check fails, and in development the page says so in a
// banner. In development the assets come from Vite's dev server running
// 0.0.19's plugin — what a `vite.config.js` importing an old gem's plugin does.
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { waitingAt, open, reset, fallback, resultFile, state, ENV } from "./support.mjs";

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

test("19-3 — the server says the page's JavaScript is another ruact's", async ({ page, request }) => {
  await page.goto("/plain");
  const banner = page.locator("[data-ruact-build-skew]");
  const doctor = await (await request.get("/__doctor")).json();
  const log = (await state(request)).build_skew_log;
  fs.writeFileSync(resultFile("skew-detected"), JSON.stringify({
    banner: (await banner.count()) ? await banner.textContent() : null, doctor, log,
  }, null, 2) + "\n");

  // Logged once, whatever the number of pages: at boot (every environment)
  // or at the first render (development).
  // Soft: the perturbation (`./run skew`) must fail at each of them, and the
  // script checks that every one did.
  expect.soft(log, "the log of the build's version").toHaveLength(1);
  expect.soft(log[0] ?? "").toContain("an older ruact, one that did not record its version");
  expect.soft(doctor.status, "the doctor's manifest check").toBe("fail");
  expect.soft(doctor.message).toContain("did not record its version");
  if (ENV === "development") {
    await expect.soft(banner, "the banner on the page").toBeVisible();
    await expect.soft(banner).toContainText("did not record its version");
  } else {
    await expect(banner).toHaveCount(0);
  }
});
