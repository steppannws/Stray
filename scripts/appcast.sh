#!/usr/bin/env bash
# Adds the zip scripts/release.sh just built to appcast.xml, signed with the Sparkle
# EdDSA key in the login keychain. Older entries in appcast.xml are kept.
#
# Usage: scripts/appcast.sh [path/to/Stray-<version>.zip]
# Then:  gh release create v<version> <zip>, and commit + push appcast.xml to main —
#        the zip must be downloadable before the feed that points at it goes live.
set -euo pipefail

cd "$(dirname "$0")/.."
ZIP="${1:-$(ls -t build/release/Stray-*.zip 2>/dev/null | head -1)}"
[[ -f "$ZIP" ]] || { echo "error: no release zip; run scripts/release.sh first" >&2; exit 1; }

VERSION=$(basename "$ZIP" .zip | sed 's/^Stray-//')
BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$BIN/generate_appcast" ]]; then
  xcodebuild -resolvePackageDependencies -project Stray.xcodeproj \
    -clonedSourcePackagesDirPath build/SourcePackages -quiet
fi

# generate_appcast gives every archive in the directory the same download prefix, so
# stage the new zip alone; entries already in appcast.xml keep their own URLs.
STAGE="build/appcast"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"

"$BIN/generate_appcast" \
  --download-url-prefix "https://github.com/steppannws/Stray/releases/download/v$VERSION/" \
  --link "https://github.com/steppannws/Stray" \
  -o appcast.xml "$STAGE"

echo "==> appcast.xml now lists $VERSION. Next:"
echo "    gh release create v$VERSION \"$ZIP\""
echo "    git add appcast.xml && git commit -m \"Release $VERSION\" && git push"
