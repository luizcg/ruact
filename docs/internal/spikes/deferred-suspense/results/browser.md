# Story 19-0 — browser runs

Written by `./run`: one row per Playwright run, Chromium, one worker.

## React 19.3.0 — Flight client: react-server-dom-webpack 19.3.0 vendored in ruact (production)

| what ran | environment | outcome |
| --- | --- | --- |
| prototype, Live | development | 10 passed |
| prototype, lazy body | development | 10 passed |
| ruact 0.0.19: `baseline.spec.mjs` | development | 2 passed |
| ruact 0.0.19: the proof, `deferred.spec.mjs` | development | 2 failed, as it must: at the shell's text and at the URL |
| the streamed document read by 0.0.19's bootstrap | development | 1 passed |
| prototype, Live | production | 1 skipped, 9 passed |
| prototype, lazy body | production | 1 skipped, 9 passed |
| ruact 0.0.19: `baseline.spec.mjs` | production | 2 passed |
| ruact 0.0.19: the proof, `deferred.spec.mjs` | production | 2 failed, as it must: at the shell's text and at the URL |
| the streamed document read by 0.0.19's bootstrap | production | 1 passed |

## React 19.2.8 — Flight client: react-server-dom-webpack 19.2.8 from the app (production)

| what ran | environment | outcome |
| --- | --- | --- |
| prototype, Live | development | 10 passed |
| prototype, lazy body | development | 10 passed |
| prototype, Live | production | 1 skipped, 9 passed |
| prototype, lazy body | production | 1 skipped, 9 passed |
