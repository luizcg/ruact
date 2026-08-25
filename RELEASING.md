# Releasing ruact

A release publishes exactly one artifact: the `ruact` gem, to RubyGems.

The Vite plugin is not a second artifact. It ships **inside** the gem at
`vendor/javascript/vite-plugin-ruact/`, a generated app imports it by filesystem path off the installed gem, and
its `package.json` carries a deliberate non-version rather than a stale one. There is nothing to co-version and
nothing to publish alongside. The standalone `vite-plugin-ruact` package on npm is a superseded artifact from
before the plugin was vendored; no ruact release touches it, and nothing this document describes puts anything
on npm.

**The release is performed by GitHub Actions, not by you.** You decide whether a merge publishes and what the
entry says; the workflow decides the number, writes it, tags it, builds and uploads. That split is the whole of
this document, and it is why every hand step this file used to prescribe has been deleted rather than corrected:
performed by hand *and* by the workflow, each of them produces a version.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the checks that run on every push and pull request and how to run
them locally — this document deliberately describes none of them, so the two cannot drift apart.

---

## Who owns what

| | Owner |
|---|---|
| Whether this merge publishes | you — a repository variable, off by default |
| What the CHANGELOG entry says | you, in the pull request |
| The version number | the `release` job, on the push to `main` |
| `lib/ruact/version.rb` | the `release` job — **it has one writer, and it is not a human** |
| The tag, the build, the upload to RubyGems | the `release` job |

---

## 1. Decide the version — and know that you are predicting it

SemVer, against the public API: a breaking change to what consumers call (a renamed public method, a changed
signature, a removed configuration option, an incompatible change to the Flight wire format) is a major; a
backwards-compatible feature is a minor; everything else is a patch.

You do not write that number anywhere. The `release` job computes it from the current one:

- **patch** by default;
- **minor** when the merge-commit message contains `[epic-done]`;
- **major** is not automated — it is a deliberate act and there is no marker for it.

> ⚠️ **You are stamping a heading for a version that does not exist yet.** The CHANGELOG entry is written in the
> pull request; the number is computed after the merge. With the default that prediction is right, because a
> patch bump is what you get. **A merge that carries the minor marker produces a minor while the heading you
> already wrote says patch**, and nothing in the workflow compares the two. Until the bump moves into the pull
> request, the mitigation is procedural: if the merge message will carry the marker, stamp the minor heading.
> `spec/changelog_spec.rb` catches the mismatch on the next push — after the fact, which is the best a
> post-merge check can do.

A minor or a major also moves the supported-versions table in [SECURITY.md](SECURITY.md). Do it in the same
pull request that stamps the CHANGELOG; nothing checks it.

---

## 2. Stamp the CHANGELOG

[CHANGELOG.md](CHANGELOG.md) is the release record and it is also the source of the changelog page on the
website, which is generated from it. Write every entry for a reader who has this repository and nothing else:
no path that resolves only somewhere private, and no link that leaves the repository except to a URL a stranger
can open.

In the pull request, move the accumulated `[Unreleased]` content under a dated heading, open a fresh empty
`[Unreleased]` above it, and update the link-reference footer at the bottom of the file:

```markdown
## [Unreleased]

## [X.Y.Z] - YYYY-MM-DD

### Added
### Changed
### Fixed
### Removed
```

```markdown
[Unreleased]: https://github.com/luizcg/ruact/compare/vX.Y.Z...HEAD
[X.Y.Z]: https://github.com/luizcg/ruact/releases/tag/vX.Y.Z
```

The date separator is a hyphen and the date is ISO. Keep only the sections that have content, and never open a
second `### Added` inside one version block — that is the shape an abandoned release leaves behind, and
`spec/changelog_spec.rb` refuses it.

**The stamp does not need its own pull request.** Both shapes are in this repository's history: a stamp-only
pull request, and a stamp riding along with the content it is stamping. Use whichever fits; the workflow does
not care and neither should the document.

---

## 3. Turn publication on

Publication is off. The `release` job runs only when a repository variable is exactly `true`:

```bash
gh variable set RUACT_AUTO_RELEASE -b true -R luizcg/ruact
```

**Why a variable and not a branch or a tag.** A merge should never be implicitly a publish. With the variable
unset the job is skipped on every push to `main`, every other check still runs, and the repository behaves
exactly as it does for someone who is not releasing. The cost is that the control is **global and stateful**:
from this command until you delete it, *any* merge to `main` publishes, not only yours. Serialise releases, and
do not leave it on while you go and fix something.

---

## 4. Merge

Merge the pull request. On the resulting push to `main`, the `release` job — which waits on every other job in
the workflow — does all of this and nothing else:

1. recomputes the version from `lib/ruact/version.rb` and writes the new one back into that file;
2. re-resolves `Gemfile.lock` against it, because a bumped version with a stale lock reddens every
   frozen-mode job on the next push;
3. commits both as `Release vX.Y.Z [skip ci]`, tags `vX.Y.Z`, and pushes the commit and the tag to `main`;
4. authenticates to RubyGems through Trusted Publishing (OIDC) — a short-lived credential minted for that run,
   no stored secret and nothing interactive — then builds and uploads the gem.

**Why the workflow owns the bump.** One writer for `lib/ruact/version.rb` means no pull request can carry a
stale one and two pull requests cannot claim the same number. Two costs come with it, and both are real: the
number is decided after you have already written the heading (§1), and the commit the published gem is built
from carries `[skip ci]`, so **the tip of `main` is the one commit no check has ever seen**.

---

## 5. Turn publication off

```bash
gh variable delete RUACT_AUTO_RELEASE -R luizcg/ruact
```

**This is the step that is dangerous to forget**, and forgetting it is silent — the next merge, days later and
by someone else, publishes a version nobody asked for. Do it as soon as the run finishes, before you verify.

---

## 6. Verify

```bash
curl -s https://rubygems.org/api/v1/versions/ruact/latest.json
```

Use that endpoint. The other one — `/gems/ruact.json` — is CDN-cached and keeps serving the previous version
for minutes after a successful publish, which reads exactly like a release that did not happen.

---

## 7. When nothing was published and nothing said so

This is the failure mode worth knowing, because from the outside a skipped release and a successful one look
identical until you check RubyGems.

**A job the `release` job waits on went red on the push to `main`.** The release job is skipped, the merge has
landed, nothing is published, and no error anywhere says "no release happened". The run that matters is the one
on `main`, not the one on the pull request:

```bash
gh run list --branch main -L 3
gh run rerun <run-id> --failed
```

**While you are re-running, publication is still on.** Any other merge in that window publishes. See §3 — the
variable is global.

**The version is on RubyGems but the API still shows the old one.** CDN cache; see §6.

**The workflow's push to `main` failed because `main` moved underneath it.** Nothing was published, the bump
commit went away with the runner, and `lib/ruact/version.rb` on `main` is untouched. Re-run rather than repair
by hand — the job recomputes everything from the file it reads.

**A release was prepared and should not go out.** Un-stamp before it merges: return the content to
`[Unreleased]`, delete the version heading and its link reference, and point `[Unreleased]`'s compare link back
at the current version. Consolidate the sections you moved back — this is the path that leaves a duplicate
`### Added` behind.

---

## 8. Rollback

If a published version has a critical defect:

```bash
gem yank ruact -v X.Y.Z
```

Then cut a patch release with the fix immediately. A yanked version with no replacement leaves anyone who
pinned it with nothing to move to. There is nothing to unpublish anywhere else — this process publishes to
RubyGems only.

---

## Where this ends

The gem is published and verified. The rest of a release — the private planning side — is outside this
repository and outside this document.
