#!/bin/bash
# Builds dist/Çentik.app (release, universal, hardened runtime). Pass --install to copy it into
# /Applications. Signs with a "Developer ID Application" certificate when the keychain has one,
# otherwise with a local certificate. Set CENTIK_SIGN_ID to pick an identity, or "-" for ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

if swift build -c release --arch arm64 --arch x86_64; then
    BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    echo "Universal build failed (it needs full Xcode); building for this Mac only." >&2
    swift build -c release
    BIN=$(swift build -c release --show-bin-path)
fi

[ -f Resources/AppIcon.icns ] || swift tools/make-icon.swift Resources

APP="dist/Çentik.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Centik" "$APP/Contents/MacOS/Centik"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# The hardened runtime stops other processes from injecting code that would inherit Çentik's
# camera, calendar and automation permissions.
SIGN=(codesign --force --options runtime --entitlements Resources/Centik.entitlements)
DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
SIGN_ID=${CENTIK_SIGN_ID:-$DEVELOPER_ID}
# Sign with a stable identity. Ad-hoc signatures change on every build, so macOS treats each
# build as a new app and asks for Automation/Calendar access again. Without a Developer ID, the
# identity lives in a private keychain under .signing/ (git-ignored), created on first use. Its
# password only guards that local, throwaway keychain.
if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
    # Notarization requires a secure timestamp.
    "${SIGN[@]}" --timestamp --sign "$SIGN_ID" "$APP"
elif [ -n "$SIGN_ID" ]; then
    "${SIGN[@]}" --timestamp=none --sign "$SIGN_ID" "$APP"
else
    KC="$PWD/.signing/centik.keychain-db"
    [ -f "$KC" ] || ./tools/make-signing-identity.sh
    security unlock-keychain -p centik-local-signing "$KC"
    "${SIGN[@]}" --timestamp=none --keychain "$KC" --sign "Centik Local Signing" "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Centik 2>/dev/null || true
    for _ in $(seq 1 50); do pgrep -x Centik >/dev/null || break; sleep 0.1; done
    rm -rf "/Applications/Çentik.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Çentik.app"
    open "/Applications/Çentik.app"
fi
