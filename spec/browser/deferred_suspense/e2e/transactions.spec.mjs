// Story 19-2 (AC16) — transactions and connections the action takes.
import fs from "node:fs";
import { test, expect } from "@playwright/test";
import { ENV, state, events, waitingAt, open, reset } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));
test.afterEach(async ({ request }) => request.post("/__db/rollback"));

const db = async (request) => (await request.get("/__db")).json();
const outcomes = {};
test.afterAll(() => fs.writeFileSync(`results/transactions-${ENV}.json`, JSON.stringify(outcomes, null, 2) + "\n"));

test("AC16.1 — the action in a transaction: the blocks run in it, and it commits after the last", async ({ page, request }) => {
  page.goto("/tx_around", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  // The transaction holds its connection from the shell to the last block.
  expect((await state(request)).pool.busy).toBe(1);
  expect(await events(request)).not.toContain("transaction about to commit");
  await open(request, "a");
  await expect(page.locator("#a")).toHaveAttribute("data-open", "true");
  await expect.poll(() => events(request)).toContain("transaction about to commit");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});

test("AC16.2 — a block's own transaction commits, and rolls back when it fails", async ({ page, request }) => {
  const before = (await db(request)).names.filter((name) => name === "from the block").length;
  await page.goto("/tx_block");
  await expect(page.locator("#a")).toHaveText("committed");
  expect((await db(request)).names.filter((name) => name === "from the block").length).toBe(before + 1);

  await page.goto("/tx_block?fail=1");
  await expect(page.getByText("Loading A…", { exact: true })).toBeVisible();
  await expect(page.locator("#a")).toHaveCount(0);
  expect((await db(request)).names.filter((name) => name === "from the block").length).toBe(before + 1);
});

test("AC16.3 — a transaction left open at the end of the action: as Rails does without streaming", async ({ page, request }) => {
  await page.goto("/tx_left_open");
  await expect(page.locator("#a")).toHaveText("a");
  const streamed = (await db(request)).open_transaction_on_checkout;
  await request.post("/__db/rollback");

  expect((await request.get("/tx_left_open_plain")).status()).toBe(200);
  const plain = (await db(request)).open_transaction_on_checkout;
  outcomes["AC16.3"] = { streamed, without_streaming: plain };
  expect(streamed).toBe(plain);
});

test("AC16.4 — a connection the action took on a page with a block goes back", async ({ page, request }) => {
  await page.goto("/leased_block");
  await expect(page.locator("#a")).toContainText("items");
  await expect.poll(async () => (await state(request)).pool.busy).toBe(0);
});
