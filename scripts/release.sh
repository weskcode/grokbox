#!/bin/bash
#
# Builds a distributable Grokbox, signs it, notarises it if it can, and prints
# the checksum to put in the release notes.
#
#   scripts/release.sh 0.5.0
#
# Signing: uses a "Developer ID Application" certificate if one is installed.
# Without it the build is ad-hoc signed and Gatekeeper will warn anyone who
# downloads it, so the script says so loudly rather than producing something
# that looks finished and is not.
#
# Notarising: needs a stored notarytool profile. Create one once with
#   xcrun notarytool store-credentials grokbox \
#     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version>   e.g. 0.5.0"; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="${TMPDIR:-/tmp}/grokbox-release-$VERSION"
OUT="$ROOT/dist"
APP="$BUILD/Build/Products/Release/Grokbox.app"
ZIP="$OUT/Grokbox-$VERSION.zip"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

say "1/7  Checking the tree"
[ -z "$(git status --porcelain)" ] || die "Working tree is dirty. Commit or stash first."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "   warning: on '$BRANCH', not main"
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml \
  || die "project.yml says $(grep MARKETING_VERSION project.yml | tr -d ' '), not $VERSION. Update it and commit."

say "2/7  Running the tests"
( cd GrokboxCore && swift test >/dev/null ) || die "Tests failed."
echo "   engine tests pass"

say "3/7  Building Release"
xcodegen generate >/dev/null
xcodebuild -project Grokbox.xcodeproj -scheme Grokbox -configuration Release \
  -derivedDataPath "$BUILD" build >/dev/null || die "Build failed."
[ -d "$APP" ] || die "No app at $APP"

say "4/7  Signing"
IDENTITY="$(security find-identity -v -p codesigning | grep '"Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements Grokbox/Grokbox.entitlements \
    --sign "$IDENTITY" "$APP"
  echo "   signed with: $IDENTITY"
  SIGNED=yes
else
  codesign --force --options runtime --entitlements Grokbox/Grokbox.entitlements --sign - "$APP"
  echo "   NO Developer ID certificate found — ad-hoc signed."
  echo "   Anyone who downloads this will see 'unidentified developer'."
  echo "   Install a Developer ID Application certificate to fix that."
  SIGNED=no
fi
codesign --verify --strict "$APP" || die "Signature does not verify."
# The sandbox is the whole privacy story; never ship without it.
codesign -d --entitlements - "$APP" 2>/dev/null | tr -d '\0' | grep -q "com.apple.security.app-sandbox" \
  || die "App sandbox entitlement missing after signing."
echo "   sandbox entitlement present"

say "5/7  Packaging"
mkdir -p "$OUT"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "   $ZIP  ($(du -h "$ZIP" | cut -f1))"

say "6/7  Notarising"
if [ "$SIGNED" = yes ] && xcrun notarytool history --keychain-profile grokbox >/dev/null 2>&1; then
  xcrun notarytool submit "$ZIP" --keychain-profile grokbox --wait || die "Notarisation failed."
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  echo "   notarised and stapled"
else
  echo "   skipped: needs a Developer ID signature and a stored 'grokbox' notarytool profile."
fi

say "7/7  Checksum"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
echo "   $SHA"

cat <<NOTES

Release $VERSION is in dist/.

  shasum -a 256 -c "$(basename "$ZIP").sha256"

Next:
  git tag -s v$VERSION -m "Grokbox $VERSION"
  git push origin v$VERSION
  gh release create v$VERSION "$ZIP" "$ZIP.sha256" --title "Grokbox $VERSION" --notes-file <notes>
NOTES
[ "$SIGNED" = yes ] || echo "NOT ready for other people: no Developer ID signature."
