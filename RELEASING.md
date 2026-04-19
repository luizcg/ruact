# Releasing ruact

This document describes the complete release process for `ruact`. Following these steps in order enables any maintainer to cut a release independently.

The gem and the `vite-plugin-ruact` npm package share the same version number and are **always released together** as a single operation.

---

## Pre-Release Checklist

Before starting, confirm all of the following:

- [ ] All CI jobs are green on `main` (rspec matrix, rubocop, yard, benchmark, e2e)
- [ ] No open issues or PRs labelled `release-blocker`
- [ ] `gem/ruact.gemspec` has no TODO placeholder values (`summary`, `homepage_uri`, `source_code_uri`, `allowed_push_host` must all be set to real values before `gem build` will succeed)
- [ ] You have a RubyGems account with push access to `ruact` and an OTP authenticator configured (MFA is required — `rubygems_mfa_required: true`)
- [ ] You have an npm account with publish access to `vite-plugin-ruact`
- [ ] You have GPG or SSH commit signing configured (recommended)

---

## Version Decision (SemVer)

Given the current version `X.Y.Z`, choose the next version:

| Change type | Version bump | Example |
|---|---|---|
| Breaking change (see below) | Major: `X+1.0.0` | `0.1.0` → `1.0.0` |
| New feature, backwards-compatible | Minor: `X.Y+1.0` | `0.1.0` → `0.2.0` |
| Bug fix, patch | Patch: `X.Y.Z+1` | `0.1.0` → `0.1.1` |

**What counts as a breaking change**: any change to the public API that requires consumers to update their code — e.g. renaming a public method, changing method signatures, removing a configuration option, or changing the Flight wire format in a non-backwards-compatible way.

---

## Release Steps

### 1. Create a release branch

```bash
git checkout -b release/v{X.Y.Z}
```

### 2. Bump the gem version

Edit `gem/lib/ruact/version.rb`:

```ruby
module Ruact
  VERSION = "{X.Y.Z}"
end
```

### 3. Bump the npm package version

Edit `packages/vite-plugin-ruact/package.json`:

```json
{
  "version": "{X.Y.Z}"
}
```

### 4. Update `gem/CHANGELOG.md`

1. Move all items under `## [Unreleased]` into a new section `## [{X.Y.Z}] - {YYYY-MM-DD}`.
2. Add a new empty `## [Unreleased]` section at the very top (above the new release section).
3. Add or update the link footer at the bottom:
   ```
   [Unreleased]: https://github.com/luizcg/ruact/compare/v{X.Y.Z}...HEAD
   [{X.Y.Z}]: https://github.com/luizcg/ruact/compare/v{PREV}...v{X.Y.Z}
   ```
4. If this release contains breaking changes, ensure the section includes a `[BREAKING]` subsection with a **Migration Guide** (see "Breaking Changes" section below).

### 5. Update `packages/vite-plugin-ruact/CHANGELOG.md`

Same format as step 4 for the npm package changelog.

### 6. Commit the release

```bash
git add gem/lib/ruact/version.rb \
        packages/vite-plugin-ruact/package.json \
        gem/CHANGELOG.md \
        packages/vite-plugin-ruact/CHANGELOG.md
git commit -m "Release v{X.Y.Z}"
```

### 7. Push the release branch and open a PR

```bash
git push origin release/v{X.Y.Z}
```

Open a PR from `release/v{X.Y.Z}` → `main`. Wait for CI to go green before continuing.

### 8. Merge, verify CI, and tag

Merge the PR. Confirm all CI jobs pass on the merge commit, then tag the verified merge commit:

```bash
git checkout main
git pull origin main
git tag v{X.Y.Z}
git push origin v{X.Y.Z}
```

> **Why tag after merge?** Tagging after CI passes on the merge commit ensures the tag always points to a verified, releasable commit. Tagging the branch commit before merge risks tagging code that fails CI after merge.

### 9. Publish the gem to RubyGems

```bash
cd gem
gem build ruact.gemspec
gem push ruact-{X.Y.Z}.gem
# Enter OTP when prompted (MFA is required)
rm ruact-{X.Y.Z}.gem
```

> **Note**: `spec.files` in the gemspec is populated via `git ls-files -z`. The files `CHANGELOG.md`, `RELEASING.md`, and `SECURITY.md` must be committed to git to appear in the gem tarball. Verify with:
> ```bash
> gem contents ruact-{X.Y.Z} | grep -E 'CHANGELOG|RELEASING|SECURITY'
> ```

### 10. Publish the npm package

```bash
cd packages/vite-plugin-ruact
npm publish
```

### 11. Create a GitHub Release

1. Go to [Releases](https://github.com/luizcg/ruact/releases/new)
2. Select tag `v{X.Y.Z}`
3. Title: `v{X.Y.Z}`
4. Body: paste the `## [{X.Y.Z}]` section from `gem/CHANGELOG.md`
5. Publish

---

## Breaking Changes

When a release contains a breaking change:

1. Bump the **major** version (e.g. `0.1.0` → `1.0.0`).
2. Mark the CHANGELOG entry with `[BREAKING]` and include a **Migration Guide** sub-section:

   ```markdown
   ## [1.0.0] - YYYY-MM-DD

   ### Changed
   - [BREAKING] `rsc_render` now requires explicit `template:` keyword for non-standard action names

   #### Migration Guide

   **Before:**
   ```ruby
   render_rsc "posts/custom"
   ```
   **After:**
   ```ruby
   rsc_render template: "posts/custom"
   ```
   ```

3. Announce the breaking change prominently in the GitHub Release body.

---

## Rollback

If a release contains a critical defect and must be pulled:

**RubyGems** (within 30 days):
```bash
gem yank ruact -v {X.Y.Z}
```

**npm** (within 72 hours):
```bash
npm unpublish vite-plugin-ruact@{X.Y.Z}
```

After yanking, cut a patch release (`{X.Y.Z+1}`) with the fix immediately. Do not leave the version yanked without a replacement.

---

## Troubleshooting

**`gem push` fails with "MFA required"**: Run `gem signin` first and ensure your OTP authenticator is set up at https://rubygems.org/settings/edit.

**Files missing from gem tarball**: The gemspec uses `git ls-files -z`. Ensure all new files (e.g. `CHANGELOG.md`) are committed to git before running `gem build`.

**CI fails on release branch**: Fix the issue on the release branch and push the fix. Wait for CI to pass before tagging. If you already pushed a tag pointing to a broken commit, delete it and recreate after the fix:
```bash
git tag -d v{X.Y.Z}                        # delete local tag
git push origin :refs/tags/v{X.Y.Z}        # delete remote tag
# fix the issue, merge, then re-tag from the correct commit
git checkout main && git pull origin main
git tag v{X.Y.Z} && git push origin v{X.Y.Z}
```
Do not use `git push --force` on tags — force-pushing a tag rewrite history for anyone who has already fetched it.
