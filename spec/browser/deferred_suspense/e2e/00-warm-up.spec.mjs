// The first page a fresh server renders in development waits for Vite to
// compile the bootstrap: done once here, so no scenario's timing pays for it.
import { test, expect } from "@playwright/test";
import { state } from "./support.mjs";

test("warm up", async ({ page, request }) => {
  await page.goto("/");
  await expect(page.locator("#home")).toBeVisible({ timeout: 60_000 });
  // Story 19-3 — the build is this ruact's: no banner, nothing logged, and the
  // doctor's manifest check passes (the negative of `./run skew`).
  await expect(page.locator("[data-ruact-build-skew]")).toHaveCount(0);
  expect((await state(request)).build_skew_log).toEqual([]);
  expect((await (await request.get("/__doctor")).json()).status).toBe("pass");
});
