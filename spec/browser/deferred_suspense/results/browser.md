# Story 19-1 — browser runs

Written by `./run`: one row per Playwright run, Chromium, one worker, against the gem in this checkout.

## React 19.3.0 — Flight client: react-server-dom-webpack 19.3.0 vendored in ruact (production)

| what ran | environment | outcome |
| --- | --- | --- |
| the scenarios | development | 49 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | development | 2 failed, as it must: at the shell's text and at the URL |
| a CSP by nonce, without 'unsafe-inline' | development | 3 passed |
| a CSP by nonce, rows pushed without it | development | 1 failed, as it must: the content never arrives, the browser refused the script |
| Puma with 3 threads (`e2e/threads.spec.mjs`) | development | 3 passed |
| nginx in front of Puma | development | not run: no nginx on the PATH |
| the scenarios | production | 1 skipped, 48 passed |
| every `<Suspense>` in place: `deferred.spec.mjs` | production | 2 failed, as it must: at the shell's text and at the URL |
| a CSP by nonce, without 'unsafe-inline' | production | 3 passed |
| a CSP by nonce, rows pushed without it | production | 1 failed, as it must: the content never arrives, the browser refused the script |
| Puma with 3 threads (`e2e/threads.spec.mjs`) | production | 3 passed |
| nginx in front of Puma | production | not run: no nginx on the PATH |

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

## Rack 2.2.24 — e2e/deferred.spec.mjs, e2e/lifecycle.spec.mjs

| what ran | environment | outcome |
| --- | --- | --- |
| the proof and the lifecycle | development | 14 passed |
| the proof without ruact's ETag | development | 2 failed, as it must: Rack::ETag held the page |
| the proof and the lifecycle | production | 1 skipped, 13 passed |
| the proof without ruact's ETag | production | 2 failed, as it must: Rack::ETag held the page |

## 0.0.19's bootstrap, this server — e2e/skew.spec.mjs

| what ran | environment | outcome |
| --- | --- | --- |
| the streamed document read by 0.0.19's bootstrap | production | measured: the fallback stays, the content never shown; 1 distinct error(s): Error: [ruact] Server error: the response ended before the whole page arrived. Detected (19-3): logged 1x, doctor fail, no banner |
| the streamed document read by 0.0.19's bootstrap | development | measured: the fallback stays, the content never shown; 1 distinct error(s): Error: [ruact] Server error: the response ended before the whole page arrived. Detected (19-3): logged 1x, doctor fail, banner on the page |
| every build taken for this ruact's: `skew.spec.mjs` | production | 1 failed, as it must: at the log and the doctor |
| every build taken for this ruact's: `skew.spec.mjs` | development | 1 failed, as it must: at the log, the doctor and the banner |
