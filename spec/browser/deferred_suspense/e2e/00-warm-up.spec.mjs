// The first page a fresh server renders in development waits for Vite to
// compile the bootstrap: done once here, so no scenario's timing pays for it.
import { test, expect } from "@playwright/test";

test("warm up", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#home")).toBeVisible({ timeout: 60_000 });
});
