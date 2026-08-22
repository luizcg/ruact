# ruact

**Real React, right in your Rails views.** Write a PascalCase tag in ERB, pass `@post` as a prop, and a React component renders — no hand-written JSON layer, no Node process in production.

[![CI](https://github.com/luizcg/ruact/actions/workflows/ci.yml/badge.svg)](https://github.com/luizcg/ruact/actions/workflows/ci.yml) [![Gem Version](https://badge.fury.io/rb/ruact.svg)](https://badge.fury.io/rb/ruact) [![codecov](https://codecov.io/gh/luizcg/ruact/branch/main/graph/badge.svg?flag=gem)](https://codecov.io/gh/luizcg/ruact)

<!-- SLOT: Story 5.2 owns this line — the write→verify demo GIF goes here, above the quick start. Story 5.14 commits no media. -->

## Quick start

```bash
# 1. A throwaway app to try it in
rails new myapp --skip-javascript && cd myapp

# 2. Add the gem
bundle add ruact

# 3. Write the config, the layout wiring and an AGENTS.md — then run npm install
rails generate ruact:install

# 4. Rails + Vite, one command
bin/dev
```

That is the whole install. The [Getting Started guide](https://ruact.dev/docs/getting-started) picks it up from here — first component, first scaffold, `ruact:doctor`. Already have an app? Start at step 2, then read [Progressive migration](https://ruact.dev/docs/guides/progressive-migration) — ruact renders one action at a time and leaves the rest of your views alone.

## How it works

```erb
<%# app/views/posts/show.html.erb %>
<PostCard post={@post} author={@author} />
```

```tsx
// app/javascript/components/PostCard.tsx
"use client"

import { useState } from "react"

export function PostCard({ post, author }) {
  const [liked, setLiked] = useState(false)
  return (
    <article>
      <h1>{post.title}</h1>
      <p>by {author.name}</p>
      <button onClick={() => setLiked(!liked)}>
        {liked ? "Liked" : "Like"}
      </button>
    </article>
  )
}
```

Rails serializes `@post` and `@author` as Ruby values, sends the component tree as a [Flight](https://ruact.dev/docs/concepts/flight-wire-format) payload, and React hydrates it in the browser. No JSON ceremony, no duplicate routes, no Node.js in production.

## Call Rails from React

Add one line to a controller and its routed non-GET actions become callable from React at their real routes:

```ruby
class PostsController < ApplicationController
  include Ruact::Server   # ← the only new line

  def create
    @post = Post.create!(post_params)
    redirect_to @post
  end
  # ...
end
```

```tsx
import { createPost } from "@/.ruact/server-functions";

await createPost({ post: { title: "Hi", body: "…" } });
```

The verb decides — there is no per-action DSL and no second endpoint. The export name is derived from the route (`posts#create` → `createPost`), and ruact's Vite plugin regenerates the module whenever your routes change. What the call *resolves* is decided by the action you already wrote: this one redirects, so ruact follows the redirect and the call resolves `null`; an action that assigns `@post` instead resolves `{ post: … }`, through the same `ruact_props` allowlist as everything else. Reading works the same way: a `Ruact::Query` class mounted with `ruact_queries` draws one named `GET` route per public method, and React reads it with `useQuery`. Both are documented in [Server functions & queries](https://ruact.dev/docs/api/server-actions).

## What you get

Every item below is shipped in this gem at v0.0.9:

- **ERB as server components** — `include Ruact::Controller`, then write PascalCase tags in your existing views. [Docs](https://ruact.dev/docs/concepts/erb-as-server-components)
- **`"use client"`** — the one directive that marks a file as client-side. The bundled Vite plugin scans for it and writes the manifest. [Docs](https://ruact.dev/docs/concepts/use-client)
- **Server functions and queries** — `include Ruact::Server` and `Ruact::Query` + `useQuery`, both reachable through a typed module generated from your route table. [Docs](https://ruact.dev/docs/api/server-actions)
- **Props are an allowlist** — `include Ruact::Serializable` + `ruact_props :id, :title`; other columns never cross. [Docs](https://ruact.dev/docs/api/serializable)
- **Validation errors round-trip** — `ruact_errors(record)` hands React `{ title: ["can't be blank"] }` without a serializer. [Docs](https://ruact.dev/docs/api/server-actions)
- **Signed record references** — `Ruact.signed_global_id(record, for:, expires_in:)` out, `Ruact.locate_signed(token, for:)` back in; a tampered token is a `400`, not a lookup. [Docs](https://ruact.dev/docs/api/server-actions)
- **Client-side navigation** — link interception, scroll restoration and redirect-after-POST, derived from your Rails routes. [Docs](https://ruact.dev/docs/concepts/navigation)
- **A CRUD generator** — `rails generate ruact:scaffold Post title:string body:text` delegates the model, migration and route to Rails' own `resource` generator, then adds the ruact layer. Plain semantic HTML by default; `--shadcn` opts into the Tailwind/shadcn path. It does not run migrations — `rails db:migrate` is still yours. [Docs](https://ruact.dev/docs/api/scaffold)
- **`bin/rails ruact:doctor`** — eight checks over the manifest, Vite, the layout and streaming; exits `1` when one fails. [Docs](https://ruact.dev/docs/api/ruact-doctor)
- **One runtime dependency** — `nokogiri`. Rails itself is not a declared dependency of this gem.

## AI tools and coding agents

**The only line you have to add to an AI-generated React component is `"use client"` at the top of the file.** One thing to check rather than add: the component needs a PascalCase *named* export, because that name is the tag you write in ERB.

1. Generate the component with whatever AI tool you already use.
2. Save it as `app/javascript/components/MyComponent.tsx`.
3. Add `"use client"` at the top if it is not already there.
4. Call `<MyComponent />` from ERB.

That is the whole adaptation, and it holds for any tool that outputs standard React components — nothing here is pinned to one vendor. The worked example, the traps and the real error messages are on [AI Tools & Agents](https://ruact.dev/docs/guides/ai-tools).

For agents driving the app rather than writing one component: `rails generate ruact:install` writes an `AGENTS.md` into your app, [ruact.dev/llms.txt](https://ruact.dev/llms.txt) serves the same context to tools that fetch from the web, and `bin/rails ruact:doctor -- --json` / `bin/rails ruact:routes -- --json` emit machine-readable output (experimental — `schema_version: 0`, and the `--` separator is required).

## Compatibility

| | Version | Where that comes from |
|---|---|---|
| Ruby | >= 3.2 | the gemspec's `required_ruby_version` |
| Rails | tested against 7.0, 7.1, 7.2 and 8.0 | every commit runs the full CI matrix; the gemspec sets no Rails bound |
| React | 19.x | the `package.json` the install generator writes |
| Node.js | >= 20 | the build only — ruact runs no Node process in production |

## Documentation

Everything lives at [ruact.dev](https://ruact.dev):

- [Getting Started](https://ruact.dev/docs/getting-started) — from `rails new` to a rendered component
- [Why ruact?](https://ruact.dev/docs/why-ruact) — where it sits next to Hotwire and Inertia
- [Server functions & queries](https://ruact.dev/docs/api/server-actions) — the full request/response contract
- [Progressive migration](https://ruact.dev/docs/guides/progressive-migration) — adopting it one action at a time
- [Testing](https://ruact.dev/docs/guides/testing) — render assertions on the server side
- [Changelog](CHANGELOG.md) — also published at [ruact.dev/docs/changelog](https://ruact.dev/docs/changelog)

## Contributing

Bug reports and pull requests are welcome at [github.com/luizcg/ruact/issues](https://github.com/luizcg/ruact/issues).

Release process: [RELEASING.md](RELEASING.md). Security policy and private reporting: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE.txt](LICENSE.txt).
