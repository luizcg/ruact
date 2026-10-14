# Spike 19-0 — evaluating the content of `<Suspense>` after the shell is sent

Experiment behind
[`../../decisions/suspense-deferred-evaluation.md`](../../decisions/suspense-deferred-evaluation.md).
Nothing here is loaded by the gem or shipped in it.

```sh
./run                 # install, build, browser runs (development + production), HTTP measurements
./run browser         # only the browser runs (writes results/browser.md)
./run measure         # only the HTTP measurements (writes results/http.md)
./run react 19.2.8    # the browser runs with the app's own react-server-dom-webpack (appends to results/browser.md)
```

Needs Ruby with Bundler, Node and curl; `wrk` for one measurement (skipped
without it). Uses ports 4190 and 5199. It runs from a plain checkout of this
repository: nothing outside it is read.

| File | What it is |
| --- | --- |
| `app.rb` | The Rails app, in one file, configured like an app `rails new` generates. `SPIKE_MODE` picks ruact as released (`baseline`) or the prototype delivered through `ActionController::Live` (`live`) or through a lazy Rack body (`body`) |
| `gate.rb` | The latch slow work waits at. A test opens it with a request of its own, so a scenario does not wait by time (the timeout measurements, which are about time, do) |
| `prototype/deferred.rb` | The prototype: the content of `<Suspense>` becomes a block, evaluated after the shell is written |
| `prototype/selective_live.rb` | `ActionController::Live` for some actions of a controller and not for others |
| `prototype/entry_tags.rb`, `app/javascript/entry.js` | The entry tag and the bootstrap for a document that stays open while rows arrive |
| `app/javascript/dev-overlay.js` | The development overlay for a `<Suspense>` that failed on the server |
| `e2e/baseline.spec.mjs` | What 0.0.19 does: nothing reaches the browser while the gate is closed |
| `e2e/deferred.spec.mjs` | The proof: shell and fallback with the gate closed, the content when it opens — first load and navigation. It fails against 0.0.19, and `./run` checks that it does |
| `e2e/lifecycle.spec.mjs` | Two boundaries, a nested one, a block that raises, what a block sees of the request, a late cookie, a slow query |
| `e2e/skew.spec.mjs` | The streamed document read by the bootstrap 0.0.19 ships |
| `measure/measure.rb` | The measurements that need no browser; each boots the app in the configuration it is about |
| `measure/rails_new_middleware.txt` | `bin/rails middleware` of a generated app, which `app.rb`'s stack is compared with |
| `results/` | What the last full run wrote: `browser.md` (one row per Playwright run), `http.md`, what a block saw of the request (`context-*.json`), the development overlay |
