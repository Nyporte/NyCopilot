# Contributing to NyCopilot

Thanks for helping. This page is how changes get from an idea to a release: branches, commits,
checks, and versions. It's short on purpose, so please read all of it.

## The short version

1. Branch from `main`: `feat/…`, `fix/…`, `docs/…`, `perf/…`, `refactor/…`, `test/…`, `chore/…`.
2. Make the change, with tests, and run `make test` locally.
3. Open a pull request whose **title** is a [Conventional Commit](#commit-messages): `fix(capture): keep the crosshair while the app in front redraws`.
4. CI must pass. The pull request is **squash-merged**: its title becomes the one commit on `main`.

`main` is protected: no direct pushes, no force-pushes, linear history, and CI must pass before a
merge. That applies to maintainers too.

## Branches

| Branch | What it's for | Lifetime |
| --- | --- | --- |
| `main` | Always releasable. Every commit passed CI. | Forever |
| `feat/<topic>` | A new capability users will notice | Until merged |
| `fix/<topic>` | A bug fix | Until merged |
| `docs/`, `perf/`, `refactor/`, `test/`, `build/`, `ci/`, `chore/` | Everything else, by kind | Until merged |
| `release/vX.Y.Z` | The version bump and changelog for one release (made by the release script) | Until merged |

Keep branches short-lived and focused: one change a reviewer can hold in their head. Rebase on
`main` rather than merging `main` in.

## Commit messages

`main` reads as one line per change, in [Conventional Commits](https://www.conventionalcommits.org) form:

```
<type>(<scope>): <what changes, for the user, in the imperative>
```

- **type**: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `revert`
- **scope** (optional): `capture`, `pin`, `gif`, `translate`, `ask`, `inbox`, `clipboard`, `windows`, `settings`, `i18n`, `core`, `release`
- Breaking changes add `!` after the type: `feat(core)!: …`

Good: `fix(capture): crosshair shows from the first moment of a capture`
Not: `Fixed stuff`, `WIP`, `update CaptureView.swift`

Commits on your branch can be anything; only the pull request title lands on `main`. Use the
pull request description for the why: what was wrong, how you found it, how you checked the fix.

## Checks

CI runs on every pull request and every push to `main` (`.github/workflows/ci.yml`):

- the pull request title is a Conventional Commit;
- the Rust core: `cargo test`, `cargo clippy -D warnings`;
- the macOS app: build, unit tests, and off-screen render tests of every panel in all ten
  interface languages (layout conflicts and cut-off text fail the build).

Run the same locally with `make test`. Behaviour that depends on the system (focus, the cursor,
windows of other apps) can't be checked off screen: describe in the pull request how you checked
it in the running app.

## README pictures

The stills in `docs/images` are NyCopilot's real panels: `NYCOPILOT_SHOWCASE=1 swift test --filter ShowcaseTests`.
The moving pictures (`demo-*.gif`) take over the screen while they record, so they're made on GitHub's
Macs: run the **Demos** workflow (or push a change to the demo tests on a branch) and download its
`demos` artifact into `docs/images`.

## Interface text and languages

Every user-facing string goes through `L("English text")`, and every language in
`apps/macos/Resources/*.lproj` must have it. `LocalizationTests` fails until all ten do, with the
same placeholders (`%@`, `%ld`, `{date}`). Counts (`%ld`) also need plural forms in
`Localizable.stringsdict` for English, Spanish, French, German, Portuguese, and Russian.

## Versions and releases

NyCopilot follows [Semantic Versioning](https://semver.org): `vMAJOR.MINOR.PATCH` tags on `main`.
Before 1.0, a `feat` raises the minor version and a `fix` or `perf` the patch; a breaking change
raises the minor version too. The build number is the commit count, so it only goes up.

Releases are cut by a maintainer with `scripts/release.sh`. See [docs/RELEASING.md](docs/RELEASING.md).

## Code

- Match the surrounding code: its naming, comment density, and idiom.
- Comments say *why*, in plain sentences; the code says what.
- No new warnings (the app builds with strict concurrency checking).
- A bug fix comes with a test that fails without it, where one can be written.

## Reporting bugs

Use **NyCopilot menu → Send Feedback…**, or open an issue with your macOS version, the app version
(About NyCopilot), what you did, and what happened. Settings → General → Copy Diagnostics adds what
the app did lately, without any of your text.
