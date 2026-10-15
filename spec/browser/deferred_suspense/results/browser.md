# Story 19-1 — browser runs

Written by `./run`: one row per Playwright run, Chromium, one worker, against the gem in this checkout.

## React 19.3.0 — Flight client: react-server-dom-webpack 19.3.0 vendored in ruact (production)

| what ran | environment | outcome |
| --- | --- | --- |
| the scenarios | development | 42 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | development | 2 failed, as it must: at the shell's text and at the URL |
| the scenarios | production | 1 skipped, 41 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | production | 2 failed, as it must: at the shell's text and at the URL |

## PostgreSQL 14.19 — e2e/postgres.spec.mjs, suspense_timeout 3 s

| what ran | environment | outcome |
| --- | --- | --- |
| PostgreSQL | development | 1 skipped, 6 passed |
| PostgreSQL, async query executor | development | 5 skipped, 2 passed |
| PostgreSQL | production | 1 skipped, 6 passed |
| PostgreSQL, async query executor | production | 5 skipped, 2 passed |
