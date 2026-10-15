# Story 19-1 — browser runs

Written by `./run`: one row per Playwright run, Chromium, one worker, against the gem in this checkout.

## React 19.3.0 — Flight client: react-server-dom-webpack 19.3.0 vendored in ruact (production)

| what ran | environment | outcome |
| --- | --- | --- |
| the scenarios | development | 49 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | development | 2 failed, as it must: at the shell's text and at the URL |
| the scenarios | production | 1 skipped, 48 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | production | 2 failed, as it must: at the shell's text and at the URL |

## PostgreSQL 14.19 — e2e/postgres.spec.mjs, suspense_timeout 5 s

| what ran | environment | outcome |
| --- | --- | --- |
| PostgreSQL | development | 1 skipped, 8 passed |
| PostgreSQL, async query executor | development | 7 skipped, 2 passed |
| PostgreSQL | production | 1 skipped, 8 passed |
| PostgreSQL, async query executor | production | 7 skipped, 2 passed |

## React 19.2.8 — Flight client: react-server-dom-webpack 19.2.8 from the app (production)

| what ran | environment | outcome |
| --- | --- | --- |
| the scenarios | development | 49 passed |
| the scenarios | production | 1 skipped, 48 passed |

## i18n 1.14.7 — e2e/middleware.spec.mjs

| what ran | environment | outcome |
| --- | --- | --- |
| middleware scopes | development | 3 passed |
| middleware scopes | production | 3 passed |
