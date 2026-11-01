# Releasing NyCopilot

A release is two steps with a review in between. Both run on a maintainer's Mac, which holds the
Developer ID certificate and the notary credentials; nothing secret is stored in GitHub.

## Once per Mac

- A **Developer ID Application** certificate in the login keychain (`make build` finds it).
- Notary credentials: `xcrun notarytool store-credentials nycopilot` (or set `NOTARY_PROFILE`).
- The GitHub CLI, signed in: `gh auth login`.

## 1. Prepare

On an up-to-date `main`:

```
scripts/release.sh prepare          # the next version, from the commits since the last tag
scripts/release.sh prepare 0.6.0    # or a version you choose
```

It sets the version in `Info.plist`, turns `## Unreleased` in `CHANGELOG.md` into a dated section
(your hand-written highlights first, then every `feat`, `fix`, and `perf` since the last tag), and
opens a `release/vX.Y.Z` pull request titled `chore(release): vX.Y.Z`.

Read the changelog in that pull request as a user would, edit it on the branch if needed, and
squash-merge it once CI is green.

## 2. Publish

On `main`, with the release pull request merged:

```
git switch main && git pull
scripts/release.sh publish
```

It checks that `main`'s last commit is the release and that CI passed on it, then builds with the
version and build number (the commit count), signs, notarizes, staples, tags `vX.Y.Z`, and
publishes a GitHub release with the zip and that version's changelog.

## Versions

[Semantic Versioning](https://semver.org). Before 1.0, a `feat` or a breaking change raises the
minor version and a `fix` or `perf` the patch. Write highlights worth reading under
`## Unreleased` as you go; the generated list covers the rest.
