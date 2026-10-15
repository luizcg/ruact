// Story 19-2 (AC13–AC15) — PostgreSQL (`./run pg`): a query held at an
// advisory lock the test holds (`harness_gate(n)`), read in pg_stat_activity.
// Run with HARNESS_TIMEOUT=3; the load_async case runs again with HARNESS_ASYNC=1.
import net from "node:net";
import { test, expect } from "@playwright/test";
import { state, events, reset } from "./support.mjs";

const ASYNC = process.env.HARNESS_ASYNC === "1";

test.beforeEach(async ({ request }) => reset(request));

const hold = (request, gate) => request.post(`/__pg/${gate}/hold`);
const release = (request, gate) => request.post(`/__pg/${gate}/release`);
const pg = async (request) => (await state(request)).pg;
const atGate = (request, count) =>
  expect.poll(async () => (await pg(request)).waiting, { timeout: 10_000, intervals: [50, 100, 200] }).toBe(count);

async function timed(request, path) {
  const started = Date.now();
  const response = await request.get(path, { timeout: 15_000 });
  return { status: response.status(), ms: Date.now() - started };
}

test("AC13.2 — the client leaves while a block's query waits: no next block, nothing left running", async ({ request }) => {
  test.skip(ASYNC, "runs without the async executor");
  await hold(request, 1);
  const socket = net.connect({ host: "localhost", port: Number(process.env.PORT ?? 4190) });
  await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  socket.write("GET /pg_slow HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\n\r\n");
  await atGate(request, 1);
  socket.destroy();

  await release(request, 1);
  await expect
    .poll(async () => (await events(request)).find((event) => event.includes("the client left")))
    .toContain("1 <Suspense> boundary was not rendered");
  expect(await events(request)).not.toContain("block_start:b");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
  await expect.poll(async () => (await pg(request)).active).toBe(0);
});

test("AC14.1 — past suspense_timeout, a query still running does not hold the next request up", async ({ page, request }) => {
  test.skip(ASYNC, "runs without the async executor");
  await hold(request, 1);
  page.goto("/pg_slow", { waitUntil: "commit" });
  await atGate(request, 1);
  // The block runs past the 3 s limit while its query waits at the gate.
  await expect
    .poll(async () => (await events(request)).some((event) => event.includes("ran past suspense_timeout")), { timeout: 10_000 })
    .toBe(true);
  await expect(page.locator("#b")).toHaveText("b");

  // The gate is still held: a request that took the abandoned query's
  // connection would wait for it.
  const quick = await timed(request, "/__pg/quick");
  expect(quick.status).toBe(200);
  expect(quick.ms).toBeLessThan(2_000);
  await expect.poll(async () => (await pg(request)).waiting).toBe(0);
  await release(request, 1);
});

// Inside a transaction: measured to pass with ruact's query watch off too —
// Active Record's own rollback of the interrupted transaction does not wait
// for the query. A regression case; the watch is what the case above needs.
test("AC14.1 — past suspense_timeout inside a transaction: the rollback does not wait for the query", async ({ page, request }) => {
  test.skip(ASYNC, "runs without the async executor");
  await hold(request, 1);
  page.goto("/pg_transaction", { waitUntil: "commit" });
  await atGate(request, 1);
  await expect(page.locator("#b")).toHaveText("b", { timeout: 10_000 });
  await expect.poll(async () => (await pg(request)).waiting).toBe(0);
  const quick = await timed(request, "/__pg/quick");
  expect(quick.ms).toBeLessThan(2_000);
  await release(request, 1);
});

test("AC14.2 — a statement timeout is the real limit: the query is cancelled, the connection is fine", async ({ page, request }) => {
  test.skip(ASYNC, "runs without the async executor");
  await hold(request, 1);
  await page.goto("/pg_statement", { waitUntil: "commit" });
  await expect(page.locator("#b")).toHaveText("b");
  await expect(page.getByText("Loading A…", { exact: true })).toBeVisible();
  expect(await events(request)).toContain("reported:ActiveRecord::QueryCanceled:ruact.suspense");
  expect((await pg(request)).waiting).toBe(0);
  const quick = await timed(request, "/__pg/quick");
  expect(quick.ms).toBeLessThan(2_000);
  await release(request, 1);
});

test("AC15.1/15.2 — two load_async queries run at once while the shell is on screen", async ({ page, request }) => {
  test.skip(!ASYNC, "needs config.active_record.async_query_executor");
  await hold(request, 1);
  await hold(request, 2);
  page.goto("/pg_async", { waitUntil: "commit" });
  await atGate(request, 2);
  await expect(page.locator("#shell")).toHaveText("Two queries at once");

  await release(request, 2);
  await expect(page.locator("#second")).toHaveCount(0);
  await release(request, 1);
  await expect(page.locator("#first")).toHaveText("2 first");
  await expect(page.locator("#second")).toHaveText("2 second");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});

test("AC15.3 — without an executor, load_async runs in the controller: no shell until the queries ran", async ({ page, request }) => {
  test.skip(ASYNC, "runs without the async executor");
  await hold(request, 1);
  await hold(request, 2);
  let answered = false;
  page.on("response", (response) => { if (response.url().endsWith("/pg_async")) answered = true; });
  page.goto("/pg_async", { waitUntil: "commit" }).catch(() => {});
  await atGate(request, 1);
  // The controller is still in its first load_async: not even the headers left.
  expect(answered).toBe(false);
  if ((process.env.RAILS_ENV ?? "development") === "development") {
    await expect
      .poll(async () => (await events(request)).filter((event) => event.includes("load_async ran its query")).length)
      .toBe(1);
  }
  await release(request, 1);
  await atGate(request, 1);
  expect(answered).toBe(false);
  await release(request, 2);
  await expect(page.locator("#first")).toHaveText("2 first");
  await expect(page.locator("#second")).toHaveText("2 second");
});
