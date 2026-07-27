#!/bin/bash
# Package /Applications/Propeller.app into a drag-to-Applications DMG (plan-v2 5.2).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Propeller"
APP="/Applications/${APP_NAME}.app"
OUT_DIR="${DMG_OUT:-../../dist}"
mkdir -p "$OUT_DIR"

if [ ! -d "$APP" ]; then
    echo "ERROR: $APP not found. Run ./build.sh first."
    exit 1
fi

if [ ! -x "$APP/Contents/MacOS/gigastt" ]; then
    echo "ERROR: gigastt missing from the app bundle — refuse to package a broken ASR build."
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "1")
STAMP=$(date +%Y%m%d)
# Prefer marketing version; append build only when it differs (avoids 6.0.0.6.0.0).
if [ "$VERSION" = "$BUILD" ]; then
    DMG_NAME="${APP_NAME}-${VERSION}-${STAMP}.dmg"
else
    DMG_NAME="${APP_NAME}-${VERSION}+${BUILD}-${STAMP}.dmg"
fi
DMG_PATH="${OUT_DIR}/${DMG_NAME}"
STAGE=$(mktemp -d /tmp/propeller-dmg-XXXXXX)

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "=== Packaging $DMG_NAME ==="
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Optional background / window styling later — keep the volume simple for R1.
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "=== DMG ready: $DMG_PATH ==="
echo "Share with COLLEAGUES.md (ПКМ → Open on first launch)."
