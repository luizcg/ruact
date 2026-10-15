# Deferred `<Suspense>` — the browser proof

Story 19-1. A one-file Rails app (`app.rb`, Puma, the middleware stack of a
`rails new`) that loads the gem from this checkout, and Playwright scenarios
that prove, in Chromium, that a page in an action declared with
`ruact_streaming` shows its shell and its `<Suspense>` fallbacks before the
slow content has run — on a first load and on a navigation, in development
and in production.

Slow work waits at a gate the test opens with a request of its own
(`gate.rb`): nothing waits by time.

```sh
./run                 # install, build, development and production, the perturbation,
                      # and the PostgreSQL scenarios when initdb is on the PATH (required on CI)
./run pg              # only the PostgreSQL scenarios (e2e/postgres.spec.mjs), on a throwaway server
./run react 19.2.8    # the scenarios with the app's own react-server-dom-webpack
./run i18n 1.14.7     # the middleware scenario with another i18n
./run rack 2.2.24     # the proof and the lifecycle with Rack 2.2
./run postgres        # what suspense_timeout does to a query running in PostgreSQL (19-1)
```

`./run` also runs the scenarios under a Content Security Policy that allows
scripts by nonce only (`HARNESS_CSP=1`, `e2e/csp.spec.mjs`), and checks that
with each boundary's rows pushed without the nonce the content never arrives.

And with Puma on three threads (`HARNESS_THREADS=3`, `e2e/threads.spec.mjs`):
the test drives the gates through a listener of its own (`control.rb`, port
4191), since every Puma thread may be busy, and reads Puma's own stats.

When nginx is on the PATH (the CI runner has it), the proof also runs behind
it (`HARNESS_NGINX=1`, `e2e/nginx.spec.mjs`, port 4192): nginx's defaults,
`proxy_http_version 1.1`, and gzip on top, each with its own configuration in
`tmp/nginx/`. Written to `results/nginx-<env>.json`; the committed ones come
from the CI runner (nginx 1.24.0, run 38790576743), the step "What ran" prints
each run's.

`./run` writes `results/browser.md`, one row per run. What a scenario measures
rather than requires goes to `results/<name>-<env>.json`; a run with another
React or i18n writes `results/<name>-<variant>-<env>.json` and leaves the
baseline alone. The navigation outcomes are also added, one line per run, to
`results/navigation-<env>.history.jsonl`. The perturbation renders
every `<Suspense>` in place, as 0.0.19 did (`HARNESS_IN_PLACE=1`, applied by
the app, not by the gem): the two scenarios of `e2e/deferred.spec.mjs` must
fail, at what the browser shows, and the script checks that they do.

`./run skew` (Story 19-2 AC22, Story 19-3) builds the assets with 0.0.19's
plugin, extracted with `git archive v0.0.19` — it needs the repository with its
tags, not an archive, and does not run on CI. It measures what that runtime
does with a streamed document (`results/skew-<env>.json`), and requires that
the server says the build is another ruact's (`e2e/skew.spec.mjs`,
`results/skew-detected-<env>.json`): the log once, the doctor's manifest
check failing (`GET /__doctor`), and in development — Vite's dev server
running 0.0.19's plugin — a banner on the page. Then the perturbation
(`HARNESS_NO_SKEW_CHECK=1`, every build taken for this ruact's) must fail it.
Every other run requires the opposite (`e2e/00-warm-up.spec.mjs`): no banner,
nothing logged, the doctor passing.

Rails' test support runs `ActionController::Live` inline, in the whole
process, so the streaming itself is only observable against a server started
on its own, as here. The gem's CI runs `./run` (job "Browser (deferred
Suspense)").

What it grew from: the 19-0 experiment in
`docs/internal/spikes/deferred-suspense/`, which proved the design against a
prototype that patched the gem.
