// Story 19-1 — one server per run, chosen by the environment:
//   RAILS_ENV=development|production   HARNESS_IN_PLACE=1 (the perturbation)
// In development Vite's dev server runs beside Rails; in production the assets
// come from `npx vite build` (see ./run).
import { defineConfig, devices } from "@playwright/test";

const env = process.env.RAILS_ENV ?? "development";
const port = Number(process.env.PORT ?? 4190);
const vitePort = Number(process.env.VITE_PORT ?? 5199);

const rails = {
  command: `bundle exec puma -t 6:6 -p ${port} config.ru`,
  url: `http://localhost:${port}/up`,
  env: {
    RAILS_ENV: env,
    PORT: String(port),
    VITE_PORT: String(vitePort),
    HARNESS_IN_PLACE: process.env.HARNESS_IN_PLACE ?? "",
    HARNESS_TIMEOUT: process.env.HARNESS_TIMEOUT ?? "",
    HARNESS_ASYNC: process.env.HARNESS_ASYNC ?? "",
    HARNESS_CSP: process.env.HARNESS_CSP ?? "",
    HARNESS_CSP_PERTURB: process.env.HARNESS_CSP_PERTURB ?? "",
    ...(process.env.DATABASE_URL ? { DATABASE_URL: process.env.DATABASE_URL } : {}),
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
  testMatch: process.env.HARNESS_IN_PLACE ? ["deferred.spec.mjs"] : process.env.HARNESS_CSP ? ["00-warm-up.spec.mjs", "csp.spec.mjs"] : process.env.HARNESS_DB === "postgres" ? ["00-warm-up.spec.mjs", "postgres.spec.mjs"] : ["00-warm-up.spec.mjs", "deferred.spec.mjs", "lifecycle.spec.mjs", "navigation.spec.mjs", "failures.spec.mjs", "placement.spec.mjs", "forms.spec.mjs", "isolation.spec.mjs", "leaving.spec.mjs", "transactions.spec.mjs", "middleware.spec.mjs", "caching.spec.mjs"],
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 5_000 },
  reporter: "list",
  use: { baseURL: `http://localhost:${port}`, trace: "retain-on-failure" },
  projects: [{ name: env, use: { ...devices["Desktop Chrome"] } }],
  webServer: env === "development" ? [vite, rails] : [rails],
});
