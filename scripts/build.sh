#!/usr/bin/env bash
# Generates the Xcode project, builds Debug and copies the app into build/.
# Usage: scripts/build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet

xcodebuild \
  -project MagicHandoff.xcodeproj \
  -scheme MagicHandoff \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true

APP="build/DerivedData/Build/Products/Debug/Magic Handoff.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
rm -rf "build/Magic Handoff.app"
cp -R "$APP" build/
echo "→ build/Magic Handoff.app"

if [ "${1:-}" = "--run" ]; then
  pkill -x "Magic Handoff" 2>/dev/null || true
  open "build/Magic Handoff.app"
fi
