// Story 19-4 — `./run upgrade`: the vite.config.js `ruact:install` writes asks
// Bundler for ruact's plugin, so an upgrade and a rebuild are the whole
// upgrade. The assets come from that config (production: the build `./run`
// made with it; development: Vite's dev server running it), the server is
// this checkout.
//
//   HARNESS_UPGRADE=quiet   the generated config, after the upgrade: the build
//                           is this ruact's, and Story 19-3's detection says
//                           nothing — no log, the doctor passes, no banner
//   HARNESS_UPGRADE=pinned  the perturbation: the config `ruact:install` wrote
//                           before 19-4, its import fixed on the gem installed
//                           then (0.0.21, extracted): the detection fires, and
//                           names that import
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { reset, resultFile, state, ENV } from "./support.mjs";

const MODE = process.env.HARNESS_UPGRADE;

test.beforeEach(async ({ request }) => reset(request));

test(`19-4 — after the upgrade and a rebuild (${MODE})`, async ({ page, request }) => {
  await page.goto("/");
  await expect(page.locator("#home")).toBeVisible({ timeout: 60_000 });
  const banner = page.locator("[data-ruact-build-skew]");
  const doctor = await (await request.get("/__doctor")).json();
  const log = (await state(request)).build_skew_log;
  fs.writeFileSync(resultFile(`upgrade-${MODE}`), JSON.stringify({
    banner: (await banner.count()) ? await banner.textContent() : null, doctor, log,
  }, null, 2) + "\n");

  if (MODE === "quiet") {
    expect.soft(log, "the log of the build's version").toEqual([]);
    expect.soft(doctor.status, "the doctor's manifest check").toBe("pass");
    await expect.soft(banner, "the banner on the page").toHaveCount(0);
  } else {
    // Soft: `./run upgrade` checks that the perturbation fails at each one.
    expect.soft(log, "the log of the build's version").toHaveLength(1);
    expect.soft(log[0] ?? "", "the import named").toContain("vite.config.js imports ruact's Vite plugin from");
    expect.soft(doctor.status, "the doctor's manifest check").toBe("fail");
    expect.soft(doctor.remediation ?? "", "the fix named").toContain("run `rails generate ruact:install`");
    if (ENV === "development") {
      await expect.soft(banner, "the banner on the page").toBeVisible();
    } else {
      await expect(banner).toHaveCount(0);
    }
  }
});
