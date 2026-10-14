// Story 19-0 — one server per run, chosen by the environment:
//   SPIKE_MODE=baseline|live|body   RAILS_ENV=development|production
// In development Vite's dev server runs beside Rails; in production the
// assets come from `npx vite build` (see ./run).
import { defineConfig, devices } from "@playwright/test";

const mode = process.env.SPIKE_MODE ?? "live";
const env = process.env.RAILS_ENV ?? "development";
const port = Number(process.env.PORT ?? 4190);
const vitePort = Number(process.env.VITE_PORT ?? 5199);

const rails = {
  command: `bundle exec puma -t 3:3 -p ${port} config.ru`,
  url: `http://localhost:${port}/up`,
  env: {
    SPIKE_MODE: mode,
    RAILS_ENV: env,
    PORT: String(port),
    VITE_PORT: String(vitePort),
    SPIKE_OLD_CLIENT: process.env.SPIKE_OLD_CLIENT ?? "",
  },
  reuseExistingServer: false,
  timeout: 120_000,
};
const vite = {
  command: "npx vite",
  url: `http://localhost:${vitePort}/@vite/client`,
  env: { VITE_PORT: String(vitePort) },
  reuseExistingServer: false,
  timeout: 60_000,
};

export default defineConfig({
  testDir: "./e2e",
  testMatch: process.env.SPIKE_OLD_CLIENT
    ? ["skew.spec.mjs"]
    : mode === "baseline"
      ? ["baseline.spec.mjs", "deferred.spec.mjs"]
      : ["deferred.spec.mjs", "lifecycle.spec.mjs"],
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 5_000 },
  reporter: "list",
  metadata: { mode, env },
  use: { baseURL: `http://localhost:${port}`, trace: "retain-on-failure" },
  projects: [{ name: `${mode}-${env}`, use: { ...devices["Desktop Chrome"] } }],
  webServer: env === "development" ? [vite, rails] : [rails],
});
