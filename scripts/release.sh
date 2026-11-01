#!/bin/zsh
# Cuts a release in two steps, with review in between (see docs/RELEASING.md):
#
#   scripts/release.sh prepare [X.Y.Z]   on an up-to-date main: bumps the version, writes the
#                                        changelog, and opens a release/vX.Y.Z pull request
#   scripts/release.sh publish           on main once that pull request is merged and CI is green:
#                                        tags, builds, signs, notarizes, and publishes the GitHub release
#
# Without X.Y.Z, prepare picks the next version from the commits since the last tag: a breaking
# change or a feat raises the minor version (before 1.0), anything else the patch. Signing and
# notarizing happen here, on the maintainer's Mac; nothing secret is stored in GitHub. Notarizing
# needs a stored notarytool profile: `xcrun notarytool store-credentials nycopilot` once, or
# NOTARY_PROFILE=<name>.
set -euo pipefail
cd "${0:A:h}/.."

plist=apps/macos/Resources/Info.plist
changelog=CHANGELOG.md

die() { print -u2 -- "release: $*"; exit 1; }

on_clean_current_main() {
  [[ $(git branch --show-current) == main ]] || die "switch to main first"
  [[ -z $(git status --porcelain) ]] || die "commit or stash changes first"
  git fetch --quiet --tags origin
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main isn't the same as origin/main; pull first"
}

last_tag() { git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true; }

# The commits a release adds, as "subject" lines: since the last tag, or all of them for the first.
subjects() {
  local tag=$(last_tag)
  if [[ -n $tag ]]; then git log --format=%s "$tag..HEAD"; else git log --format=%s; fi
}

next_version() {
  local tag=$(last_tag) current major minor patch
  current=${tag#v}
  [[ -n $current ]] || current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $plist)
  IFS=. read major minor patch <<< $current
  if [[ -z $tag ]] || subjects | grep -Eq '^(feat(\(.*\))?|[a-z]+(\(.*\))?!):'; then
    print "$major.$((minor + 1)).0"
  else
    print "$major.$minor.$((patch + 1))"
  fi
}

# What users get, grouped: features, fixes, speed. Housekeeping (docs, ci, chore…) stays out.
notes() {
  local heading pattern
  for heading pattern in "New" '^feat' "Fixed" '^fix' "Faster" '^perf'; do
    local lines=$(subjects | grep -E "${pattern}(\([^)]*\))?!?: " | sed -E 's/^[a-z]+(\(([^)]*)\))?!?: (.*)$/\3/' | awk '{ print "- " toupper(substr($0, 1, 1)) substr($0, 2) }' || true)
    [[ -n $lines ]] && print "### $heading\n\n$lines\n"
  done
  true
}

prepare() {
  on_clean_current_main
  local version=${1:-$(next_version)}
  [[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "version must be X.Y.Z, got $version"
  git rev-parse -q --verify "refs/tags/v$version" >/dev/null && die "v$version is already tagged"
  local branch="release/v$version"

  # Hand-written highlights under "## Unreleased" lead the section; generated notes follow.
  local highlights=$(awk '/^## Unreleased/{on=1; next} /^## /{on=0} on' $changelog | sed -e '/./,$!d')
  local section=$(
    print -r -- "## $version — $(date +%Y-%m-%d)"; print
    [[ -n $highlights ]] && { print -r -- "$highlights"; print }
    notes
  )
  # Through the environment: awk -v can't take a value with line breaks.
  SECTION=$section awk '
    /^## Unreleased/ { print; print ""; printf "%s\n\n", ENVIRON["SECTION"]; skip=1; next }
    skip && /^## / { skip=0 }
    !skip { print }
  ' $changelog > $changelog.new
  mv $changelog.new $changelog
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" $plist

  git switch --quiet -c $branch
  git commit --quiet -am "chore(release): v$version"
  git push --quiet -u origin $branch
  gh pr create --base main --head $branch --title "chore(release): v$version" \
    --body "Release v$version. Merging this, then \`scripts/release.sh publish\` on main, tags and publishes it.

$(print -r -- "$section" | sed 1d)"
  git switch --quiet main
  print "Opened the release pull request for v$version. Merge it when CI is green, then: scripts/release.sh publish"
}

publish() {
  on_clean_current_main
  local subject=$(git log -1 --format=%s)
  [[ $subject =~ '^chore\(release\): v([0-9]+\.[0-9]+\.[0-9]+)' ]] || die "main's last commit isn't a merged release pull request (got: $subject)"
  local version=$match[1] build=$(git rev-list --count HEAD)
  local ci=$(gh run list --commit $(git rev-parse HEAD) --workflow ci.yml --json conclusion --jq '.[0].conclusion')
  [[ $ci == success ]] || die "CI on main isn't green for this commit yet (${ci:-not run})"
  local profile=${NOTARY_PROFILE:-nycopilot}
  local zip="dist/NyCopilot-$version.zip"

  make build VERSION=$version BUILD_NUMBER=$build
  rm -f $zip
  ditto -c -k --keepParent dist/NyCopilot.app $zip
  xcrun notarytool submit $zip --keychain-profile $profile --wait
  xcrun stapler staple dist/NyCopilot.app
  rm -f $zip
  ditto -c -k --keepParent dist/NyCopilot.app $zip
  spctl --assess --type execute --verbose dist/NyCopilot.app

  local body=$(awk -v v="## $version " 'index($0, v) == 1 {on=1; next} /^## /{on=0} on' $changelog | sed -e '/./,$!d')
  git tag -a "v$version" -m "NyCopilot $version"
  git push --quiet origin "v$version"
  gh release create "v$version" $zip --title "NyCopilot $version" --notes "$body"
  print "Published NyCopilot $version ($build)."
}

case ${1:-} in
  prepare) shift; prepare "$@" ;;
  publish) publish ;;
  *) die "usage: scripts/release.sh prepare [X.Y.Z] | publish" ;;
esac
