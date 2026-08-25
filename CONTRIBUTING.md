# Contributing to ruact

Thanks for wanting to change something here. This guide takes you from a fresh clone to an open pull
request, and everything it asks you to run, you can run — with this repository and nothing else.

## What this repository is

`luizcg/ruact` is one repository holding three things that ship together:

| Directory | What lives there |
|---|---|
| `lib/` | the Ruby library — the ERB preprocessor, the render pipeline, the Flight wire format, the Rails integration, the generators and the Rake tasks |
| `vendor/javascript/vite-plugin-ruact/` | the Vite plugin — it scans for `"use client"`, emits the client manifest, and generates the typed server-function accessors |
| `vendor/javascript/ruact-server-functions-runtime/` | the browser-side runtime those generated accessors call |

The two JavaScript packages are **bundled, not published**. A host app never installs them from npm:
`rails generate ruact:install` writes a `vite.config.js` that imports the plugin by absolute path off the
installed gem. That has one consequence worth stating up front, because it is what makes the rest of this
document short — **pointing a Rails app at your checkout of the gem points it at your checkout of the Vite
plugin too.** There is nothing to link separately, and nothing else to clone. This repository has no
submodules.

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| Ruby | >= 3.2 | the floor in `ruact.gemspec`; CI runs 3.2 and 3.3 |
| Node.js | 20 | the JavaScript suite and the asset build only — ruact runs no Node process in production |
| Bundler | any recent | `gem install bundler` |

Rails is **not** required to run the Ruby suite. `spec/support/rails_stub.rb` supplies the pieces the
library touches and steps aside when real Rails is already loaded, so the fast loop needs no Rails at all.

## Setup

```bash
git clone https://github.com/luizcg/ruact.git
cd ruact
bundle install
```

That is the whole setup for a Ruby-side change. If you are touching the Vite plugin or the browser
runtime, install their dependencies too:

```bash
cd vendor/javascript/ruact-server-functions-runtime && npm install
cd ../vite-plugin-ruact && npm ci
```

The first install is not decoration: the plugin's test run reaches into the runtime package, which keeps
`react` in its own dependencies.

## Running the checks

These are the jobs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which runs on every pull
request. Running them locally first is the difference between one round and four.

<!-- ci-jobs:begin -->

| CI job | What it checks |
|---|---|
| `rspec` | the Ruby suite, on Ruby 3.2/3.3 × Rails 7.0/7.1/7.2/8.0 — eight cells |
| `rubocop` | style, plus the three custom cops below |
| `yard` | every public method carries YARD documentation |
| `js` | the Vite plugin's vitest suite, including its Ruby↔JS byte-parity cases, and a type-level test over the generated accessors |
| `benchmark` | render-pipeline allocations against a recorded baseline |
| `name-propagation` | greps the tree for names retired before v0.1.0 |

<!-- ci-jobs:end -->

There is one more job, `release`, which publishes to RubyGems. It is off unless a maintainer turns it on
and never runs on a pull request; you will not need it. See [RELEASING.md](RELEASING.md) for the release
process itself — this document deliberately describes none of it, so the two cannot drift apart.

Locally:

```bash
bundle exec rspec
bundle exec rubocop --format github
rm -rf .yardoc doc && bundle exec yard --fail-on-warning
bundle exec rake benchmark:memory
```

and, for the `js` job:

```bash
cd vendor/javascript/vite-plugin-ruact
npm test
npm run typecheck
```

To reproduce one matrix cell against real Rails rather than the stub:

```bash
RAILS_VERSION=8.0 bundle install && bundle exec rspec
```

## Trying your working tree in a real app

The suite is fast and the gates are strict, and neither tells you whether your change works in a Rails
app. This does, in about two minutes. `RUACT` is the absolute path to your clone.

```bash
export RUACT=/absolute/path/to/your/ruact

rails new myapp --skip-javascript
cd myapp
printf '\ngem "ruact", path: "%s"\n' "$RUACT" >> Gemfile
bundle install
bin/rails generate ruact:install
bin/dev
```

No published gem and no published npm package take part: the `path:` source points Bundler at your
checkout, and the generated `vite.config.js` imports the Vite plugin from inside it. Both halves of your
change are live.

Give it something to render — a component in `app/javascript/components/`:

```jsx
"use client";
import { useState } from "react";

export function LikeButton({ likes }) {
  const [count, setCount] = useState(likes);
  return <button onClick={() => setCount(count + 1)}>{count} likes</button>;
}
```

a controller action, and a view that uses the component by name:

```erb
<h1>Home</h1>
<LikeButton likes={@likes} />
```

`bin/dev` runs Rails and Vite together. Load the page and the button counts up.

## Four gates that fail for reasons your diff does not show

Most of CI fails where you expect. These four do not, so they are worth knowing before they surprise you.

1. **`spec/readme_spec.rb`** — `README.md` is pinned **byte for byte** in places: the quick-start block and
   the demo image reference are compared against literals in the spec, the file is allowed exactly one raw
   `<img>`, and a `path:` gem source is forbidden there because a reader who copies one installs nothing.
   Edit the README casually and this goes red.

   ⚠️ **One of its assertions is repository-wide despite living in a README spec.** It runs `git ls-files`
   over the whole repository and fails if any tracked file is a `.gif`, `.mp4`, `.webm` or `.webp` — media
   committed here would ship inside every built `.gem` and stay in the clone history forever. So **no
   document in this repository can carry an image**, including this one. Media lives with the documentation
   site and is referenced by absolute URL.

   ⚠️ **YARD reads `README.md`.** Curly braces in its prose — `{@likes}`, `{Foo#bar}` — are link macros to
   YARD, and an unresolvable one turns the `yard` job red for a README edit. Write them as `&#123;` and
   `&#125;` there.

2. **`spec/readme_demo_message_spec.rb`** — the second half of that pin, covering the demo's message.

3. **`spec/benchmarks/render_pipeline_benchmark_spec.rb`** — an **allocation** baseline at ×1.20 tolerance
   against `spec/benchmarks/baseline.json`, shared by matrix cells that legitimately differ by around 9%.
   When it fails, read the header comment at the top of that file before doing anything: it explains how to
   tell a real regression from accumulated drift, and how to regenerate the baseline if it is drift.

4. **Three custom RuboCop cops**, in `lib/rubocop/cop/ruact/` and enabled in `.rubocop.yml`. Custom cops are
   the least discoverable failure a newcomer can hit, so they are named here rather than left to the error
   message:
   - `Ruact/NoSharedState` — no `Thread.current`, no class variables.
   - `Ruact/NoIoInFlight` — no file I/O under `lib/ruact/flight/**`; the serializer stays pure Ruby.
   - `Ruact/NoExtendSelf` — use `module_function` or instance methods on a class.

And one habit rather than a gate: run `yard` after `rm -rf .yardoc doc`, as the block above does. A warm
cache hides warnings that CI, which checks out fresh, still reports.

## Where a change goes

Every destination below is one you can reach.

| Change | Where |
|---|---|
| anything under `lib/`, `app/`, `exe/`, `sig/`, `spec/` | **here** — `luizcg/ruact` |
| a typo in `README.md`, `CHANGELOG.md` or this file | **here** |
| the Vite plugin | **here**, at `vendor/javascript/vite-plugin-ruact/` — see the note below |
| the browser runtime for server functions | **here**, at `vendor/javascript/ruact-server-functions-runtime/` |
| the documentation site at `ruact.dev` | not in this repository — [open an issue](https://github.com/luizcg/ruact/issues) |
| roadmap, architecture decisions, design | not in this repository — [open an issue](https://github.com/luizcg/ruact/issues) or a discussion |

**About the Vite plugin.** There is an older, separate `luizcg/vite-plugin-ruact` repository, and an
`vite-plugin-ruact` package on npm last published in May 2026. Both are **superseded**: nothing in ruact
installs them, and the plugin that actually runs is the vendored one in this repository. A pull request
opened there would land in an artifact nobody uses, so send plugin changes here.

## Where the design work happens

Roadmap, architecture decisions and story planning live in a private repository, so the reasoning behind a
change is not always visible from here. That does not gate anything: open an issue or a discussion, and the
outcome of that thinking comes back to you in the thread — you do not need access to propose a change,
argue for one, or land one.

## Opening the pull request

Branch off `main`, keep one topic per pull request, and open it against `luizcg/ruact`. Before you do:

- [ ] `bundle exec rspec` passes.
- [ ] `bundle exec rubocop --format github` is clean.
- [ ] `rm -rf .yardoc doc && bundle exec yard --fail-on-warning` passes, and every new public method has a
      YARD comment with `@param` and `@return`.
- [ ] `# frozen_string_literal: true` is the first line of every new Ruby file.
- [ ] Nothing you added lives in `Ruact::`'s way: gem code stays under `Ruact::`, wire-format code under
      `Ruact::Flight::`, and no Ruby or Rails core class is reopened.
- [ ] If you touched the Vite plugin or the runtime, `npm test` and `npm run typecheck` pass in
      `vendor/javascript/vite-plugin-ruact`.
- [ ] [CHANGELOG.md](CHANGELOG.md) has an entry under `[Unreleased]` describing the change for a reader who
      did not see the diff.

Describe what the change does and why in the pull request body. If it fixes a reported bug, link the issue.

Security issues do **not** go in a pull request — see [SECURITY.md](SECURITY.md) for private reporting.

By contributing you agree that your contribution is licensed under the MIT license in
[LICENSE.txt](LICENSE.txt).
