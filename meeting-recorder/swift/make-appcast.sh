#!/bin/bash
# Build appcast.xml for the latest DMG in ../../dist (Sparkle / plan-v2 5.3).
set -euo pipefail
cd "$(dirname "$0")"

DIST="${DMG_OUT:-../../dist}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
PRIV_KEY="${SPARKLE_PRIVATE_KEY_FILE:-sparkle/private/eddsa_priv.key}"
FEED_BASE="${SU_DOWNLOAD_BASE:-https://github.com/levalovushka/propeller/releases/latest/download}"

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "ERROR: Sparkle tools missing. Run: swift package resolve && swift build -c release"
    exit 1
fi
if [ ! -f "$PRIV_KEY" ]; then
    echo "ERROR: private key not found at $PRIV_KEY"
    echo "Export with: $SPARKLE_BIN/generate_keys --account propeller -x $PRIV_KEY"
    exit 1
fi

DMG=$(ls -t "$DIST"/Propeller-*.dmg 2>/dev/null | head -1 || true)
if [ -z "$DMG" ]; then
    echo "ERROR: no Propeller-*.dmg in $DIST — run ./package-dmg.sh first"
    exit 1
fi

DMG_NAME=$(basename "$DMG")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Propeller.app/Contents/Info.plist 2>/dev/null || echo "0.1")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Propeller.app/Contents/Info.plist 2>/dev/null || echo "1")
# Outputs: sparkle:edSignature="…" length="…"
ED_ATTRS=$("$SPARKLE_BIN/sign_update" --account propeller --ed-key-file "$PRIV_KEY" "$DMG" | tr -d '\n')
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="${FEED_BASE}/${DMG_NAME}"

OUT="$DIST/appcast.xml"
cat > "$OUT" << XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Propeller</title>
    <link>${FEED_BASE}/appcast.xml</link>
    <description>Propeller updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}" type="application/octet-stream" ${ED_ATTRS} />
    </item>
  </channel>
</rss>
XML

echo "=== Appcast: $OUT ==="
echo "Upload both to the GitHub Release:"
echo "  $DMG"
echo "  $OUT"
echo "Asset names must match enclosure URLs (latest/download/${DMG_NAME} + appcast.xml)."
