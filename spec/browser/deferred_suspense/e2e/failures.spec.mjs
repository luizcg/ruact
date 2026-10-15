// Story 19-2 (AC5–AC7) — failures once the response has started.
import { test, expect } from "@playwright/test";
import { ENV, state, events, waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

function watchErrors(page) {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text()));
  return errors;
}

test("AC5.1 — a layout that raises: before any byte, an ordinary 500", async ({ page }) => {
  const response = await page.goto("/two?layout_raises=1");
  expect(response.status()).toBe(500);
  await expect(page.locator("#shell")).toHaveCount(0);
});

for (const how of ["first load", "navigation"]) {
  test(`AC5.2 — a failure after the first write, outside a block (${how}): the page stays, labelled`, async ({ page, request }) => {
    const errors = watchErrors(page);
    if (how === "navigation") await page.goto("/");
    await request.post("/__fail_stream");
    if (how === "navigation") await page.click("#to-two");
    else await page.goto("/two", { waitUntil: "commit" });

    await waitingAt(request, { a: 1 });
    await open(request, "a");
    await expect(page.locator("#a")).toHaveText("open:a");
    await expect(fallback(page, "B")).toBeVisible();
    await expect(page).toHaveURL(/\/two$/);
    await expect(page.locator("#shell")).toHaveText("Two");

    await expect
      .poll(() => errors.join("\n"))
      .toContain("[ruact] Server error: the response ended before the whole page arrived");
    expect(await page.content()).not.toContain("500.html");
    expect(await events(request)).toEqual(expect.arrayContaining([
      expect.stringContaining("raised while streaming"),
      "reported:RuntimeError:ruact.stream",
    ]));
    await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
  });
}

for (const how of ["first load", "navigation"]) {
  test(`AC6.1 — an after_action that writes after the page was sent (${how}): the browser never gets it`, async ({ page, request }) => {
    const sent = page.waitForResponse((response) => new URL(response.url()).pathname === "/after_write");
    if (how === "navigation") {
      await page.goto("/");
      await page.evaluate(() => {
        const a = document.createElement("a");
        a.id = "to-after-write";
        a.href = "/after_write";
        document.body.append(a);
        a.textContent = "after write";
      });
      await page.click("#to-after-write");
    } else {
      page.goto("/after_write");
    }
    await waitingAt(request, { a: 1 });
    await open(request, "a");
    await expect(page.locator("#a")).toHaveText("open:a");
    // Nor the header: the response had started.
    expect((await sent).headers()["x-after"]).toBeUndefined();

    // The action has ended: ruact has compared what the after_action wrote.
    await expect.poll(async () => (await events(request)).includes("action done:after_write")).toBe(true);
    const names = (await page.context().cookies()).map((cookie) => cookie.name);
    expect(names).not.toContain("after");
    const line = async () => (await events(request)).find((event) => event.includes("code after the page was sent")) ?? "";
    if (ENV === "development") {
      await expect.poll(line).toContain("PagesController#after_write");
      expect(await line()).toContain("the cookie after");
      expect(await line()).toContain("the header x-after");
    } else {
      expect(await line()).toBe("");
    }
  });
}

test("AC7 — several failures in one overlay, with the template's file and line", async ({ page, request }) => {
  const errors = watchErrors(page);
  await page.goto("/errors", { waitUntil: "commit" });
  await waitingAt(request, { b: 1 });

  if (ENV === "development") {
    const overlay = page.locator("#ruact-dev-overlay");
    await expect(overlay.locator("[data-overlay-message]")).toHaveText([/the first failure/]);
    await open(request, "b");
    await expect(overlay.locator("[data-overlay-message]")).toHaveText([/the first failure/, /the second failure/]);
    await expect(overlay.locator("[data-overlay-title]")).toHaveText("[ruact] 2 <Suspense> failed on the server");
    const stacks = await overlay.locator("[data-overlay-stack]").allTextContents();
    expect(stacks[0]).toMatch(/errors\.html\.erb:2\b/);
    expect(stacks[1]).toMatch(/errors\.html\.erb:3\b/);
    await overlay.click();
    await expect(overlay).toHaveCount(0);

    await open(request, "c");
    await expect(page.locator("#ruact-dev-overlay [data-overlay-message]")).toHaveText([/the third failure/]);
  } else {
    await open(request, "b");
    await open(request, "c");
    await expect.poll(() => errors.filter((text) => text.includes("[ruact] Server error")).length).toBe(3);
    // Once the document has ended and React has rendered what it brought:
    // still three, no failure reported twice.
    await page.waitForFunction(() => document.readyState === "complete");
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0))));
    expect(errors.filter((text) => text.includes("[ruact] Server error"))).toHaveLength(3);
    await expect(page.locator("#ruact-dev-overlay")).toHaveCount(0);
    expect(errors.join("\n")).not.toContain("the first failure");
  }
  await expect(fallback(page, "A")).toBeVisible();
  await expect(fallback(page, "C")).toBeVisible();
});

// Story 19-2 (AC10.2) — `content_for` inside a block runs after the layout was
// sent: in development, an error of that block; in production, lost (the block
// renders).
test("AC10.2 — content_for inside a block", async ({ page }) => {
  await page.goto("/content_for_block");
  if (ENV === "development") {
    await expect(page.locator("#ruact-dev-overlay [data-overlay-message]")).toContainText("content_for :late_title");
    await expect(fallback(page, "A")).toBeVisible();
  } else {
    await expect(page.locator("#a")).toHaveText("the block ran");
    await expect(page.locator("#ruact-dev-overlay")).toHaveCount(0);
  }
});
