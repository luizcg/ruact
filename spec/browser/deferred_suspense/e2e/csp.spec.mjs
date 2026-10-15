// Story 19-2 (AC21) — an app whose Content Security Policy allows scripts by
// nonce only, without 'unsafe-inline' (HARNESS_CSP=1): every script ruact
// writes carries the request's nonce — the payload, the entry, and each
// boundary's rows pushed while the document streams. The perturbation
// (HARNESS_CSP_PERTURB=1) pushes the rows without it: the content never comes.
import { test, expect } from "@playwright/test";
import { ENV, waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

// React's Flight client tries eval() in development, for its debugging
// features ("React will never use eval() in production mode", its own
// message): under a policy without 'unsafe-eval' that is refused, and React
// goes on. Not ruact's; the only refusal development may show.
const REACT_DEV_EVAL = /\beval\b/;
const ours = (refusals) => (ENV === "development" ? refusals.filter((text) => !REACT_DEV_EVAL.test(text)) : refusals);

// What the browser refused, as the page saw it.
async function watchViolations(page) {
  await page.addInitScript(() => {
    window.__violations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      window.__violations.push(`${event.violatedDirective} ${event.blockedURI}`);
    });
  });
  const console = [];
  page.on("console", (message) => message.text().includes("Content Security Policy") && console.push(message.text()));
  return console;
}

for (const how of ["first load", "navigation"]) {
  test(`AC21 — a CSP by nonce: shell, fallback, then the content (${how})`, async ({ page, request }) => {
    const refused = await watchViolations(page);
    const sent = page.waitForResponse((response) => ["/", "/two"].includes(new URL(response.url()).pathname));
    if (how === "navigation") {
      await page.goto("/");
      await page.click("#to-two");
    } else {
      page.goto("/two", { waitUntil: "commit" });
    }
    const policy = (await sent).headers()["content-security-policy"] ?? "";
    expect(policy).toMatch(/script-src [^;]*'nonce-/);
    expect(policy).not.toContain("unsafe-inline' ; script");

    await waitingAt(request, { a: 1 });
    await expect(fallback(page, "A")).toBeVisible();
    await open(request, "a");
    await expect(page.locator("#a")).toHaveText("open:a");
    await open(request, "b");
    await expect(page.locator("#b")).toHaveText("open:b");
    expect(ours(await page.evaluate(() => window.__violations))).toEqual([]);
    expect(ours(refused)).toEqual([]);
  });
}
