# Story 19-1 — browser runs

Written by `./run`: one row per Playwright run, Chromium, one worker, against the gem in this checkout.

## React 19.3.0 — Flight client: react-server-dom-webpack 19.3.0 vendored in ruact (production)

| what ran | environment | outcome |
| --- | --- | --- |
| the scenarios | development | 21 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | development | 2 failed, as it must: at the shell's text and at the URL |
| the scenarios | production | 1 skipped, 20 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | production | 2 failed, as it must: at the shell's text and at the URL |
