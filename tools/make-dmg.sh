#!/bin/bash
# Builds dist/Centik.dmg from a fresh release build: the app plus an Applications shortcut.
#
# With a "Developer ID Application" certificate in the keychain, the DMG is signed, sent to
# Apple for notarization and stapled, so it opens without a Gatekeeper warning. Notarization
# uses the notarytool keychain profile in NOTARY_PROFILE (default "centik"), created once with:
#   xcrun notarytool store-credentials centik --apple-id <email> --team-id <team>
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

DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$DEVELOPER_ID" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" dist/Centik.dmg
    PROFILE=${NOTARY_PROFILE:-centik}
    echo "Submitting to Apple for notarization (usually a few minutes)…"
    RESULT=$(xcrun notarytool submit dist/Centik.dmg --keychain-profile "$PROFILE" --wait --output-format json)
    STATUS=$(plutil -extract status raw - <<<"$RESULT")
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization failed: $STATUS" >&2
        xcrun notarytool log "$(plutil -extract id raw - <<<"$RESULT")" --keychain-profile "$PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple dist/Centik.dmg
    spctl --assess --type open --context context:primary-signature --verbose dist/Centik.dmg
else
    echo "No Developer ID certificate: the DMG is not notarized." >&2
fi
shasum -a 256 dist/Centik.dmg
echo "Built dist/Centik.dmg ($VERSION)"
