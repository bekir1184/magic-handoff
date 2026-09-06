#!/usr/bin/env bash
# Builds a Release app signed with Developer ID, notarises it and staples the
# ticket, producing dist/Magic-Handoff-<version>.zip that opens on any Mac
# without the "unidentified developer" block.
#
# One-time setup (both need your Apple account, so they are not scripted):
#   1. Xcode → Settings → Accounts → your team → Manage Certificates →
#      "+" → Developer ID Application.   (needs a paid membership)
#   2. xcrun notarytool store-credentials magic-handoff \
#        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#      (create the app-specific password at appleid.apple.com)
#
# Usage: scripts/release.sh            # full: sign + notarise + staple
#        scripts/release.sh --no-notarize
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0
PROFILE="magic-handoff"

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -z "$IDENTITY" ]; then
  echo "No 'Developer ID Application' certificate in the keychain."
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates, then rerun."
  exit 1
fi
echo "Signing identity: $IDENTITY"

xcodegen generate --quiet
rm -rf build/Release
xcodebuild \
  -project MagicHandoff.xcodeproj -scheme MagicHandoff -configuration Release \
  -derivedDataPath build/Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP="build/Release/Build/Products/Release/Magic Handoff.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/Magic-Handoff-$VERSION-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" = "1" ]; then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarisation credentials stored under keychain profile '$PROFILE'."
    echo "Run: xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>"
    exit 1
  fi
  echo "Submitting to Apple notary service…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP" || true
fi

echo "→ $ZIP"
