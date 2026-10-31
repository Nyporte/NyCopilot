#!/bin/zsh
# Builds, signs, notarizes, and packages a release from a version tag.
#
#   git tag v0.4.0 && scripts/release.sh
#
# The version comes from the tag (vX.Y.Z), the build number from the commit count. Notarizing
# needs a stored notarytool profile: `xcrun notarytool store-credentials nycopilot` once, or
# NOTARY_PROFILE=<name>. The result is dist/NyCopilot-<version>.zip, stapled, ready to publish.
set -euo pipefail
cd "${0:A:h}/.."

tag=$(git describe --tags --exact-match 2>/dev/null || true)
[[ $tag == v* ]] || { echo "Tag the commit first: git tag vX.Y.Z" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash changes first." >&2; exit 1; }
version=${tag#v}
build=$(git rev-list --count HEAD)
profile=${NOTARY_PROFILE:-nycopilot}

make build VERSION="$version" BUILD_NUMBER="$build"
zip="dist/NyCopilot-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent dist/NyCopilot.app "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple dist/NyCopilot.app
rm -f "$zip"
ditto -c -k --keepParent dist/NyCopilot.app "$zip"
spctl --assess --type execute --verbose dist/NyCopilot.app
echo "Released $version ($build): $zip"
