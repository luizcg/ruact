import { expect } from "@playwright/test";

export const ENV = process.env.RAILS_ENV ?? "development";

export async function state(request) {
  return (await request.get("/__state")).json();
}

/** Resolves when the server is blocked at exactly these gates. */
export async function waitingAt(request, gates) {
  await expect
    .poll(async () => (await state(request)).waiting, { timeout: 10_000, intervals: [50, 100, 200] })
    .toEqual(gates);
}

export async function open(request, name) {
  await request.post(`/__gate/${name}/open`);
}

export async function reset(request) {
  await request.post("/__gate/reset");
}

export const events = async (request) => (await state(request)).events;

/** A value that lives as long as the document does. */
export async function documentOf(page) {
  return page.evaluate(() => (window.__harnessDocument ??= crypto.randomUUID()));
}

export const fallback = (page, name) => page.getByText(`Loading ${name}…`, { exact: true });
export const clicker = (page, label) => page.locator(`[data-clicker="${label}"]`);
