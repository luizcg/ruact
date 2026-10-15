// Story 19-2 (AC11) — a form that answers 422 on a page with a <Suspense>, and
// `ruact_errors` read inside the block.
import { test, expect } from "@playwright/test";
import { ENV, events, waitingAt, open, reset, fallback } from "./support.mjs";

test.beforeEach(async ({ request }) => reset(request));

const loading = (page) => page.getByText("Loading the errors…", { exact: true });

async function openForm(page, request, path = "/items/new") {
  await page.goto(path, { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#errors")).toHaveText("{}");
  await reset(request);
}

test("AC11.2 — create streams: through the router, a 422 with the shell first and the errors in the block", async ({ page, request }) => {
  await openForm(page, request);
  const answered = page.waitForResponse((r) => r.url().endsWith("/items") && r.request().method() === "POST");
  await page.fill("#name", "x");
  await page.click("#save");
  expect((await answered).status()).toBe(422);
  await waitingAt(request, { a: 1 });
  await expect(loading(page)).toBeVisible();
  await expect(page).toHaveURL(/\/items\/new$/);
  await open(request, "a");
  await expect(page.locator("#errors")).toContainText("name");
});

test("AC11.2 — create streams: a native submit gets a 422 document, the errors in the block", async ({ page, request }) => {
  await openForm(page, request);
  await page.evaluate(() => document.getElementById("item-form").setAttribute("data-turbo", "false"));
  // A native submit: the router lets a form with a target go.
  await page.evaluate(() => document.getElementById("item-form").setAttribute("target", "_self"));
  await page.fill("#name", "x");
  const answered = page.waitForResponse((r) => r.url().endsWith("/items") && r.request().method() === "POST");
  await page.evaluate(() => HTMLFormElement.prototype.submit.call(document.getElementById("item-form")));
  expect((await answered).status()).toBe(422);
  await waitingAt(request, { a: 1 });
  await expect(loading(page)).toBeVisible();
  await open(request, "a");
  await expect(page.locator("#errors")).toContainText("name");
});

test("AC11.3 — create does not stream: the 422 renders whole, and development names the line to add", async ({ page, request }) => {
  await openForm(page, request);
  await page.evaluate(() => document.getElementById("item-form").setAttribute("action", "/items/in_place"));
  await open(request, "a"); // the in-place block waits at the same gate
  await page.fill("#name", "x");
  const answered = page.waitForResponse((r) => r.url().endsWith("/items/in_place"));
  await page.click("#save");
  expect((await answered).status()).toBe(422);
  await expect(page.locator("#errors")).toContainText("name");
  await expect(loading(page)).toHaveCount(0);
  const note = (await events(request)).find((event) => event.includes("does not stream")) ?? "";
  if (ENV === "development") expect(note).toContain("ruact_streaming only: :create_in_place");
  else expect(note).toBe("");
});

test("AC11.4 — errors through the flash are read in the block once, and not on the next page", async ({ page, request }) => {
  await openForm(page, request);
  await page.evaluate(() => document.getElementById("item-form").setAttribute("action", "/items/redirect"));
  await page.fill("#name", "x");
  await page.click("#save");
  await expect(page).toHaveURL(/\/items\/new$/);
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#errors")).toContainText("name");

  await reset(request);
  await page.goto("/items/new", { waitUntil: "commit" });
  await waitingAt(request, { a: 1 });
  await open(request, "a");
  await expect(page.locator("#errors")).toHaveText("{}");
});
