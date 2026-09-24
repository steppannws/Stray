#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized, stapled Stray.app and zips it for release.
#
# One-time setup:
#   1. A "Developer ID Application" certificate for team 97AYLS48JS in the login
#      keychain (Xcode → Settings → Accounts → Manage Certificates → +).
#   2. Notary credentials stored under the profile this script uses:
#        xcrun notarytool store-credentials stray-notary \
#          --apple-id <apple id> --team-id 97AYLS48JS
#      (prompts for an app-specific password from appleid.apple.com)
#
# Usage: scripts/release.sh           → build/release/Stray-<version>.zip
#        NOTARY_PROFILE=other scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-stray-notary}"
OUT="build/release"
APP="$OUT/Stray.app"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Archiving"
xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$OUT/Stray.xcarchive" \
  -allowProvisioningUpdates -quiet archive

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/Stray.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$OUT" \
  -allowProvisioningUpdates -quiet

# Refuse to notarize anything that is not what we meant to ship: a build signed with
# the development certificate would be rejected by the notary anyway, only later.
codesign --verify --deep --strict "$APP"
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "error: $APP is not signed with a Developer ID Application certificate" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

echo "==> Notarizing $VERSION ($BUILD)"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
# `notarytool submit --wait` can exit 0 on a rejected submission, so check the verdict
# itself and print the notary's log when it is anything but Accepted.
RESULT=$(xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" \
  --wait --output-format json)
STATUS=$(plutil -extract status raw - <<< "$RESULT")
if [[ "$STATUS" != "Accepted" ]]; then
  ID=$(plutil -extract id raw - <<< "$RESULT")
  echo "error: notarization finished with status '$STATUS'" >&2
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi
rm "$OUT/notarize.zip"

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="$OUT/Stray-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> $ZIP"
