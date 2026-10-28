#!/bin/bash
# Builds dist/Centik.dmg from a fresh release build: the app plus an Applications shortcut.
# Release DMGs are built locally so every version carries the same signature, which lets macOS
# keep users' permissions across updates.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "dist/Çentik.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Centik.dmg
hdiutil create -volname "Çentik $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 dist/Centik.dmg >/dev/null
shasum -a 256 dist/Centik.dmg
echo "Built dist/Centik.dmg ($VERSION)"
