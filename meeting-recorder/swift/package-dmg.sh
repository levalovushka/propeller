#!/bin/bash
# Package /Applications/Propeller.app into a drag-to-Applications DMG (plan-v2 5.2).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Propeller"
APP="/Applications/${APP_NAME}.app"
OUT_DIR="${DMG_OUT:-../../dist}"
ASSETS="packaging/dmg"
mkdir -p "$OUT_DIR"

# Window is exactly the background's point size — Finder anchors the picture at the top left and
# never scales it, so any other size shows the seam.
#
# The artwork is 660x400 and background.tiff is 660x432: the extra 32 pt at the bottom continues the
# artwork's own bottom edge (#FFFFFF today), and it is there because the Finder path bar is a *global*
# preference, not a window one — nothing in the .DS_Store can turn it off for whoever opens the
# image. When it is on it eats ~28 pt off the bottom of the icon view, which cropped the caption
# clean in half. With the padding, a viewer who has the path bar on sees the composition as drawn,
# and a viewer who has it off sees the same plus a strip the eye cannot separate from the artwork.
#
# The top of the artwork is light on purpose: it is where the icons sit. Finder draws the
# "Propeller" and "Applications" labels in dark text, in every theme, and nothing can recolour them.
# Measured, not assumed: there is no text colour property in its icon view options; setting
# "background color" to match does nothing (checked on a freshly named volume, so no Finder cache
# was in the way); and a text size below 10 does not shrink the label but voids the whole icon view
# record — Finder then drops the background, the icon size and the window geometry with it (stored
# 8.0, applied icon size 48). Over a dark background those labels are black on black.
#
# Rebuild background.tiff from the two exports after any redesign — match the pad colour to the
# artwork's own bottom row:
#   ffmpeg -i background.png     -vf pad=660:432:0:0:color=#FFFFFF  padded.png
#   ffmpeg -i background@2x.png  -vf pad=1320:864:0:0:color=#FFFFFF padded@2x.png
#   tiffutil -cathidpicheck padded.png padded@2x.png -out background.tiff
WIN_W=660
WIN_H=432
ICON_SIZE=128
APP_X=220
APP_Y=200
DROP_X=444
DROP_Y=200

if [ ! -d "$APP" ]; then
    echo "ERROR: $APP not found. Run ./build.sh first."
    exit 1
fi

if [ ! -x "$APP/Contents/MacOS/gigastt" ]; then
    echo "ERROR: gigastt missing from the app bundle — refuse to package a broken ASR build."
    exit 1
fi

# The app has to carry its own notarization ticket before it is sealed into the image.
# Stapling the DMG afterwards does not reach inside it, and a Sparkle update installs the
# app *without* the DMG — so an unstapled app here ships an update that has to phone Apple
# on first launch and blocks if it cannot. SKIP_NOTARIZE=1 is for iterating on the image's
# appearance, never for a release.
if [ "${SKIP_NOTARIZE:-0}" != "1" ] && ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "ERROR: $APP has no notarization ticket. Run ./notarize.sh first."
    echo "       (SKIP_NOTARIZE=1 packages an unnotarized image — appearance work only.)"
    exit 1
fi

if [ ! -f "$ASSETS/background.tiff" ]; then
    echo "ERROR: $ASSETS/background.tiff missing. Rebuild it from the PNG pair:"
    echo "  tiffutil -cathidpicheck $ASSETS/background.png $ASSETS/background@2x.png -out $ASSETS/background.tiff"
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
MOUNT="/Volumes/${APP_NAME}"

cleanup() {
    hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

echo "=== Packaging $DMG_NAME ==="
CONTENT="$STAGE/content"
mkdir -p "$CONTENT/.background"
cp "$ASSETS/background.tiff" "$CONTENT/.background/background.tiff"
cp -R "$APP" "$CONTENT/"
ln -s /Applications "$CONTENT/Applications"

# The drag-to-Applications screen is Finder window state, not a property of the image: background,
# window size, icon size and icon coordinates live in the volume's .DS_Store. Finder can only write
# that to a mounted read-write volume, and it records the background as a bookmark carrying the
# volume's UUID — which is why the styled volume must be *converted* to the shipping image rather
# than rebuilt from a folder. Rebuilding silently drops the background and keeps everything else.
RW_DMG="$STAGE/rw.dmg"
SIZE_MB=$(( $(du -sm "$CONTENT" | cut -f1) + 120 ))
hdiutil create -srcfolder "$CONTENT" -volname "$APP_NAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov -quiet "$RW_DMG"

hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -quiet
[ -d "$MOUNT" ] || { echo "ERROR: volume did not mount at $MOUNT"; exit 1; }

echo "=== Arranging the window (Finder needs Automation permission for this step) ==="
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        -- These two are per-window and land in the .DS_Store. The path bar deliberately is not
        -- here: "pathbar visible" writes the account's *global* Finder preference, so setting it
        -- would silently turn the path bar off on the packaging machine and still not travel with
        -- the image. It is handled by the padding on the background instead — see WIN_H above.
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 200 + $WIN_W, 120 + $WIN_H}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        -- Off by default in this account, but it is inherited, and "Приложение, 430 МБ" under the
        -- icon is exactly the noise the designed background is there to avoid.
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to true
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "${APP_NAME}.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$DROP_X, $DROP_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store lazily; the volume has to be flushed before it is worth converting.
sync
sleep 2
if [ ! -f "$MOUNT/.DS_Store" ]; then
    echo "ERROR: Finder never wrote .DS_Store — the window was not styled."
    exit 1
fi

hdiutil detach "$MOUNT" -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -ov -quiet

# Sign and notarize the image itself. This is what decides whether a person who downloads it
# sees the app or "Propeller is damaged" — the app's own ticket does not cover the container.
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    # Read once, parse after — the same `pipefail` + early-exiting-filter trap that made
    # notarize.sh reject a correctly signed image (see its comment).
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    DMG_SIGN_HASH=$(awk '/Developer ID Application/ {print $2; exit}' <<< "$IDENTITIES")
    if [ -z "$DMG_SIGN_HASH" ]; then
        echo "ERROR: no Developer ID Application identity — cannot sign the image."
        exit 1
    fi
    echo "=== Signing the image ==="
    codesign --force --sign "$DMG_SIGN_HASH" --timestamp "$DMG_PATH"
    ./notarize.sh "$DMG_PATH"
else
    echo "=== SKIP_NOTARIZE=1: unsigned, unnotarized image — do not ship this ==="
fi

# The landing page's "Download" button links to a stable, ever-green name
# (releases/latest/download/${APP_NAME}.dmg) so the site never needs editing on release day.
# Every release therefore ships a second asset under that name, next to the versioned one.
# It must be a hard link, not a copy: the DMG is ~390 MB and dist/ already holds a dozen of
# them, and a hard link on APFS costs no extra space. This name must never collide with the
# Propeller-*.dmg glob make-appcast.sh uses to pick the image to sign — "Propeller.dmg" has no
# hyphen after the app name, so it does not match that pattern.
#
# The link is made *after* stapling on purpose: the ticket is written into the image, and a
# link taken before it would either miss the ticket or leave two names disagreeing about
# which bytes are the release.
STABLE_PATH="${OUT_DIR}/${APP_NAME}.dmg"
rm -f "$STABLE_PATH"
if ! ln "$DMG_PATH" "$STABLE_PATH"; then
    echo "ERROR: failed to hard-link $STABLE_PATH -> $DMG_PATH — this asset ships in the release."
    exit 1
fi

echo ""
echo "=== DMG ready: $DMG_PATH ==="
echo "=== Stable alias: $STABLE_PATH ==="
echo "Upload both to the release (versioned + stable name)."
echo "Notarized and stapled — a first launch is a double click, no ПКМ → Открыть."
