// Story 19-2 (AC19) — nginx in front of Puma (HARNESS_NGINX=1, needs nginx on
// the PATH): does the shell reach the browser before the gate opens, on a
// first load and on a navigation, with nginx's defaults, with
// `proxy_http_version 1.1`, and with gzip on top. Each variant runs its own
// nginx, spawned here with a configuration written to tmp/.
//
// Written to results/nginx-<env>.json. Asserted: the defaults send the page
// whole (nginx talks HTTP/1.0 upstream, so Live cannot stream) and log the
// AC20 warning; HTTP/1.1 sends the shell first. Gzip is measured only.
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { test, expect } from "@playwright/test";
import { ENV, waitingAt, open, reset, fallback, events, resultFile } from "./support.mjs";

const UPSTREAM = Number(process.env.PORT ?? 4190);
const LISTEN = UPSTREAM + 2;
const PROXY = `http://localhost:${LISTEN}`;
const VARIANTS = {
  defaults: "",
  "proxy_http_version 1.1": "proxy_http_version 1.1;",
  "proxy_http_version 1.1, gzip on": "proxy_http_version 1.1;\n      gzip on;\n      gzip_types text/html text/x-component;",
};

function startNginx(name, directives) {
  const prefix = path.resolve("tmp", "nginx", name.replace(/\W+/g, "-"));
  for (const dir of ["", "temp"]) fs.mkdirSync(path.join(prefix, dir), { recursive: true });
  const conf = path.join(prefix, "nginx.conf");
  fs.writeFileSync(conf, `worker_processes 1;
daemon off;
pid ${prefix}/nginx.pid;
error_log ${prefix}/error.log;
events { worker_connections 64; }
http {
  access_log off;
  client_body_temp_path ${prefix}/temp/body;
  proxy_temp_path ${prefix}/temp/proxy;
  fastcgi_temp_path ${prefix}/temp/fastcgi;
  uwsgi_temp_path ${prefix}/temp/uwsgi;
  scgi_temp_path ${prefix}/temp/scgi;
  server {
    listen ${LISTEN};
    location / {
      proxy_pass http://127.0.0.1:${UPSTREAM};
      proxy_set_header Host $http_host;
      ${directives}
    }
  }
}
`);
  const nginx = spawn("nginx", ["-p", prefix, "-c", conf], { stdio: "ignore" });
  return nginx;
}

async function proxyUp(request) {
  await expect.poll(async () => (await request.get(`${PROXY}/up`).catch(() => null))?.status() ?? 0, { timeout: 10_000 }).toBe(200);
}

// Whether the fallback was on screen while the gate was still closed.
async function shellFirst(page, request, how) {
  await reset(request);
  if (how === "navigation") {
    await page.goto(`${PROXY}/`);
    await page.click("#to-two");
  } else {
    page.goto(`${PROXY}/two`, { waitUntil: "commit" }).catch(() => {});
  }
  await waitingAt(request, { a: 1 });
  // The one wait by time: how long the shell is given to come through the proxy.
  const early = await fallback(page, "A").waitFor({ state: "visible", timeout: 3_000 }).then(() => true, () => false);
  await open(request, "a");
  await open(request, "b");
  await expect(page.locator("#b")).toHaveText("open:b", { timeout: 10_000 });
  return early;
}

const measured = { env: ENV };
test.afterAll(() => fs.writeFileSync(resultFile("nginx"), JSON.stringify(measured, null, 2) + "\n"));

for (const [name, directives] of Object.entries(VARIANTS)) {
  test(`AC19 — nginx, ${name}: the shell before the gate opens?`, async ({ page, request }) => {
    measured.nginx ??= spawnSync("nginx", ["-v"], { encoding: "utf8" }).stderr.trim();
    const nginx = startNginx(name, directives);
    try {
      await proxyUp(request);
      const document = await shellFirst(page, request, "first load");
      // AC20 — said once per process: the defaults run first, after the warm-up.
      const warned = (await events(request)).some((event) => event.includes("came over HTTP/1.0"));
      const navigation = await shellFirst(page, request, "navigation");
      measured[name] = { first_load_shell_before_the_gate: document, navigation_shell_before_the_gate: navigation };
      if (name === "defaults") {
        measured[name].ac20_warning_logged = warned;
        expect({ document, navigation, warned }).toEqual({ document: false, navigation: false, warned: true });
      } else if (name === "proxy_http_version 1.1") {
        expect({ document, navigation }).toEqual({ document: true, navigation: true });
      }
    } finally {
      nginx.kill("SIGTERM");
      await new Promise((resolve) => nginx.once("exit", resolve));
    }
  });
}
