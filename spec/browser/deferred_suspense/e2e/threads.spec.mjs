// Story 19-2 (AC18) — what streaming does to Puma's threads (HARNESS_THREADS=3).
// A page that streams holds its thread until its last <Suspense>: streaming
// changes when the browser gets the page, not how many slow requests the
// server holds. The test drives the gates through a listener of its own
// (control.rb), since every Puma thread may be busy.
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { resultFile } from "./support.mjs";

const CONTROL = `http://127.0.0.1:${Number(process.env.PORT ?? 4190) + 1}`;
const control = async (request, path) => (await request.get(`${CONTROL}${path}`)).json();
const puma = async (request) => (await control(request, "/state")).puma;
const busyAt = (request, busy, backlog = 0) =>
  expect
    .poll(async () => { const now = await puma(request); return [now.busy, now.backlog]; },
      { timeout: 10_000, intervals: [50, 100, 200] })
    .toEqual([busy, backlog]);
const waitingAt = (request, gates) =>
  expect.poll(async () => (await control(request, "/state")).waiting, { timeout: 10_000, intervals: [50, 100, 200] }).toEqual(gates);

const measured = {};
test.afterAll(() => fs.writeFileSync(resultFile("threads"), JSON.stringify(measured, null, 2) + "\n"));
test.beforeEach(async ({ request }) => control(request, "/reset"));

test("AC18.1 — three pages at a gate hold the three threads; a fourth request waits", async ({ browser, request }) => {
  const pages = await Promise.all([1, 2, 3].map(() => browser.newPage()));
  pages.forEach((page) => page.goto("/two", { waitUntil: "commit" }).catch(() => {}));
  await waitingAt(request, { a: 3 });
  await expect.poll(async () => (await puma(request)).busy).toBe(3);
  // In production Puma serves the pages' own JavaScript too (no Vite server):
  // those requests queue behind the three that stream. Read once they settle.
  let queued = -1;
  await expect.poll(async () => {
    const before = (await puma(request)).backlog;
    const settled = before === queued;
    queued = before;
    return settled;
  }, { timeout: 10_000, intervals: [300] }).toBe(true);

  // A page with no <Suspense> at all: it waits for a thread.
  let answered = false;
  const fourth = request.get("/plain").then((response) => { answered = true; return response; });
  await busyAt(request, 3, queued + 1);
  expect(answered).toBe(false);

  await control(request, "/open/a");
  await control(request, "/open/b");
  expect((await fourth).status()).toBe(200);
  await busyAt(request, 0);
  measured["AC18.1"] = {
    threads: 3, at_the_gate: 3, busy: 3,
    queued_behind_them_before_the_fourth: queued,
    fourth_request: "queued until a gate opened",
  };
  await Promise.all(pages.map((page) => page.close()));
});

test("AC18.3 — one user: a document still streaming and a navigation hold two threads", async ({ page, request }) => {
  await page.goto("/two", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await busyAt(request, 1);

  await page.click("#to-two-again");
  await waitingAt(request, { a: 2 });
  // The router stopped the document, but its block is still at the gate.
  await busyAt(request, 2);

  await control(request, "/open/a");
  await waitingAt(request, { b: 1 });
  // The document's request saw its client leave before its next block.
  await busyAt(request, 1);
  await control(request, "/open/b");
  await expect(page.locator("#b")).toHaveText("open:b");
  await busyAt(request, 0);
  measured["AC18.3"] = { while_the_first_block_waits: 2, once_it_ended: 1 };
});
