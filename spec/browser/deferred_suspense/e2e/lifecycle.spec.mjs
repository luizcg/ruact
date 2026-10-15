// Story 19-1 — past the happy path, against the gem: order, errors, what a
// block sees of the request, what the response can no longer carry, the
// connection pool, a client that leaves.
import fs from "node:fs";
import net from "node:net";
import { test, expect } from "@playwright/test";
import { ENV, state, events, waitingAt, open, reset, fallback, clicker, resultFile } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

test("the page mounts before the document ends", async ({ page, request }) => {
  await page.goto("/slow", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  expect(await page.evaluate(() => document.readyState)).toBe("loading");
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
});

// The document's head arrives in one piece, so here the parser has reached
// #root before the async entry runs: this is the regression check that such a
// layout mounts and streams. The wait for a #root that comes later
// (`whenRoot`) is proved in page-mount.test.mjs.
test("a layout that puts the assets above #root still mounts, before the document ends", async ({ page, request }) => {
  await page.goto("/slow?assets_first=1", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  await clicker(page, "shell").click();
  await expect(clicker(page, "shell")).toHaveText("shell: 1");
  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
});

// Blocks run one at a time, in the order the page has them.
test("two boundaries: opening the second gate first changes nothing until the first opens", async ({ page, request }) => {
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "b");
  // B's block has not started: nobody is at gate b.
  expect(await events(request)).toEqual(["block_start:a"]);
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect
    .poll(() => events(request))
    .toEqual(["block_start:a", "block_end:a", "block_start:b", "block_end:b", "action done:two"]);
});

test("a boundary inside a boundary: the inner one is found when the outer block runs", async ({ page, request }) => {
  await page.goto("/nested", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  await expect(fallback(page, "B")).toHaveCount(0);

  await open(request, "a");
  await expect(page.locator("#a")).toHaveText("open:a");
  await waitingAt(request, { b: 1 });
  await expect(fallback(page, "B")).toBeVisible();

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
});

// The response is already 200: the error goes to the boundary.
test("a block that raises: its boundary keeps the fallback, the next block still runs", async ({ page, request }) => {
  const errors = [];
  page.on("console", (message) => message.type() === "error" && errors.push(message.text()));

  const response = await page.goto("/error", { waitUntil: "commit" });
  expect(response.status()).toBe(200);
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible(); // mounted: the error arrives later
  await open(request, "a");

  await waitingAt(request, { b: 1 });
  expect(await events(request)).toContain("reported:NoMethodError:ruact.suspense");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#a")).toHaveCount(0);

  if (ENV === "development") {
    const overlay = page.locator("#ruact-dev-overlay");
    await expect(overlay).toBeVisible();
    await expect(overlay.locator("[data-overlay-message]")).toContainText("NoMethodError");
    await expect(overlay.locator("[data-overlay-message]")).toContainText("total");
    // The Ruby backtrace, rebuilt by React's development client: the template is in it.
    await expect(overlay.locator("[data-overlay-stack]")).toContainText("error_html_erb");
    await page.screenshot({ path: "results/overlay.png" });
    await overlay.click();
    await expect(overlay).toHaveCount(0);
  } else {
    // Production says that it failed, and nothing about why.
    await expect.poll(() => errors.join("\n")).toContain("[ruact] Server error: An error occurred in a <Suspense>");
    await expect(page.locator("#ruact-dev-overlay")).toHaveCount(0);
    expect(errors.join("\n")).not.toContain("NoMethodError");
  }

  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b");
});

// The same error, already in the stream when React mounts: caught in the first
// commit, before any effect has run.
test("a block that had already raised when the page mounts", async ({ page, request }) => {
  test.skip(ENV !== "development", "the overlay is development only");
  await open(request, "a");
  await open(request, "b");
  await page.goto("/error");
  await expect(page.locator("#b")).toHaveText("open:b");
  await expect(fallback(page, "A")).toBeVisible();
  await expect(page.locator("#ruact-dev-overlay [data-overlay-message]")).toContainText("NoMethodError");
});

// ADR D3: what the block sees of what the request set up.
test("what a deferred block sees of the request", async ({ page, request }) => {
  await page.goto("/context", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#in-block")).toBeVisible();

  const read = (id) =>
    page.locator(`#${id} li`).evaluateAll((items) => Object.fromEntries(items.map((li) => [li.dataset.k, li.textContent])));
  const shell = await read("in-shell");
  const block = await read("in-block");
  const lazy = { shell: await page.locator("#shell-lazy").textContent(), block: await page.locator("#block-lazy").textContent() };
  await expect.poll(async () => (await events(request)).includes("action done:context")).toBe(true);
  const order = await events(request);
  fs.writeFileSync(resultFile("context"), JSON.stringify({ shell, block, lazy, events: order }, null, 2) + "\n");

  expect(shell).toMatchObject({ locale: "pt", t: "olá", zone: "Tokyo", tenant: "acme", current: '"ada"' });
  expect(lazy).toEqual({ shell: "lazy lookup (pt)", block: "lazy lookup (pt)" });
  // The action is still running: its around_action is on the stack.
  expect(block).toMatchObject({
    locale: "pt", t: "olá", zone: "Tokyo", tenant: "acme", current: '"ada"', thread: "other thread",
  });
  expect(order.indexOf("after_action")).toBeGreaterThan(order.indexOf("block_end:a"));
});

// ADR D5: the response started before the block ran.
test("a cookie or session write inside a block", async ({ page, request }) => {
  await page.goto("/late_cookie", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");

  if (ENV === "development") {
    // An error of the block, saying where the write goes.
    const overlay = page.locator("#ruact-dev-overlay [data-overlay-message]");
    await expect(overlay).toContainText("the cookie late");
    await expect(overlay).toContainText("set in the controller, before the page renders");
    await expect(page.locator("#a")).toHaveCount(0);
  } else {
    await expect(page.locator("#a")).toHaveText("cookie written");
  }

  // Either way the browser never got it: the response had started.
  const names = (await page.context().cookies()).map((cookie) => cookie.name);
  expect(names).toContain("early");
  expect(names).not.toContain("late");
  expect(await (await page.request.get("/__session")).json()).toMatchObject({ early: "1", late: null });
});

// A lazy relation is loaded where the view walks it: inside the block.
test("a slow query inside a block holds one connection while it runs, and gives it back", async ({ page, request }) => {
  await page.goto("/db", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await expect(fallback(page, "A")).toBeVisible();
  expect((await state(request)).pool.busy).toBe(1);

  await open(request, "a");
  await expect(page.locator("#a li")).toHaveText(["one", "two"]);
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});

// ADR D4: under Live the action runs in a thread of the pool, and Rails gives
// back what the request's thread leased, not what that one did.
test("a connection the action leased is back in the pool when it ends", async ({ request }) => {
  for (let i = 0; i < 4; i++) expect((await request.get("/leased")).status()).toBe(200);
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});

test("an action left out of ruact_streaming keeps the request's thread", async ({ page }) => {
  await page.goto("/plain");
  await expect(page.locator("#thread")).toHaveText("request thread");
});

// ADR D4: the server does not notice on its own; ruact asks before each block.
// The client is a plain socket closed while the first block waits: a closed
// tab is not a closed connection everywhere (headless Chromium on Linux kept
// it open), and this is about what the server does once the connection is gone.
test("a client that leaves: the next block does not start", async ({ request }) => {
  const socket = net.connect({ host: "localhost", port: Number(process.env.PORT ?? 4190) });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  socket.write("GET /two HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\n\r\n");
  await waitingAt(request, { a: 1 });
  socket.destroy();

  await open(request, "a");
  await expect
    .poll(async () => (await events(request)).find((event) => event.includes("the client left")))
    .toContain("1 <Suspense> boundary was not rendered");
  expect(await events(request)).not.toContain("block_start:b");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});
