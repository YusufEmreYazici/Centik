#!/bin/bash
# Creates a local code-signing identity in a private keychain at .signing/ (git-ignored).
#
# A stable signature lets macOS remember the Automation and Calendar permissions across
# rebuilds; ad-hoc signatures change every build. The login keychain and its search list are
# left untouched: build.sh points codesign at this keychain directly.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=".signing"
KC="$PWD/$DIR/centik.keychain-db"
PW="centik-local-signing"
NAME="Centik Local Signing"

if [ -f "$KC" ]; then
    echo "Signing keychain already exists: $KC"
    exit 0
fi

mkdir -p "$DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout pass:"$PW" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout pass:"$PW"

SEARCH_LIST=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
security create-keychain -p "$PW" "$KC"
# create-keychain may add the new keychain to the user's search list; put the list back as it was.
# shellcheck disable=SC2086
security list-keychains -d user -s $SEARCH_LIST
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/identity.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
echo "Created $NAME in $KC"
