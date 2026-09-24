#!/usr/bin/env bash
# Publishes the build in dist/ so people can install it:
#   - creates (or updates) the GitHub release for this version
#   - uploads the versioned zip and a fixed-name copy, so
#     .../releases/latest/download/Magic-Handoff.zip always points at the newest
#     build and the download button on the site never needs editing
#   - updates the Homebrew cask in the bekir1184/homebrew-tap repository
#
# Run scripts/release.sh first; it builds, signs, notarises and staples.
#
# Usage: scripts/publish.sh [--notes-file FILE] [--no-tap]
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES_FILE=""
UPDATE_TAP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --no-tap) UPDATE_TAP=0; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

REPO="bekir1184/magic-handoff"
TAP_REPO="bekir1184/homebrew-tap"

APP="build/Release/Build/Products/Release/Magic Handoff.app"
[ -d "$APP" ] || { echo "No Release build found. Run scripts/release.sh first."; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
ZIP="dist/Magic-Handoff-$VERSION-$BUILD.zip"
[ -f "$ZIP" ] || { echo "$ZIP is missing. Run scripts/release.sh first."; exit 1; }

# Refuse to publish a build Apple has not blessed: it would greet everyone with
# a Gatekeeper warning.
xcrun stapler validate "$APP" >/dev/null 2>&1 || { echo "$APP has no notarisation ticket stapled."; exit 1; }

STABLE="dist/Magic-Handoff.zip"
cp "$ZIP" "$STABLE"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
TAG="v$VERSION"

echo "Publishing $VERSION ($BUILD)"
echo "  sha256 $SHA"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" "$STABLE" -R "$REPO" --clobber
  echo "  updated release $TAG"
else
  if [ -n "$NOTES_FILE" ]; then
    gh release create "$TAG" "$ZIP" "$STABLE" -R "$REPO" --title "Magic Handoff $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" "$ZIP" "$STABLE" -R "$REPO" --title "Magic Handoff $VERSION" --generate-notes
  fi
  echo "  created release $TAG"
fi

[ "$UPDATE_TAP" = "1" ] || { echo "Skipped the Homebrew tap."; exit 0; }

TAP_DIR=$(mktemp -d)
trap 'rm -rf "$TAP_DIR"' EXIT
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/magic-handoff.rb" <<CASK
cask "magic-handoff" do
  version "$VERSION,$BUILD"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version.csv.first}/Magic-Handoff-#{version.csv.first}-#{version.csv.second}.zip",
      verified: "github.com/$REPO/"
  name "Magic Handoff"
  desc "Moves Magic Keyboard, Trackpad and Mouse between two Macs with one keystroke"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Magic Handoff.app"

  zap trash: [
    "~/Library/Logs/Magic Handoff.log",
    "~/Library/Preferences/com.bekirersever.magichandoff.plist",
  ]
end
CASK

git -C "$TAP_DIR" add Casks/magic-handoff.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "  cask already up to date"
else
  git -C "$TAP_DIR" commit -q -m "magic-handoff $VERSION ($BUILD)"
  git -C "$TAP_DIR" push -q
  echo "  updated the cask in $TAP_REPO"
fi

echo
echo "Install line: brew install --cask bekir1184/tap/magic-handoff"
echo "Download link: https://github.com/$REPO/releases/latest/download/Magic-Handoff.zip"
