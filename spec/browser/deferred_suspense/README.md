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
./run                 # install, build, development and production, and the perturbation
./run react 19.2.8    # the same with the app's own react-server-dom-webpack
./run postgres        # what suspense_timeout does to a query running in PostgreSQL
```

`./run` writes `results/browser.md`, one row per run. The perturbation renders
every `<Suspense>` in place, as 0.0.19 did (`HARNESS_IN_PLACE=1`, applied by
the app, not by the gem): the two scenarios of `e2e/deferred.spec.mjs` must
fail, at what the browser shows, and the script checks that they do.

Rails' test support runs `ActionController::Live` inline, in the whole
process, so the streaming itself is only observable against a server started
on its own, as here. The gem's CI runs `./run` (job "Browser (deferred
Suspense)").

What it grew from: the 19-0 experiment in
`docs/internal/spikes/deferred-suspense/`, which proved the design against a
prototype that patched the gem.
