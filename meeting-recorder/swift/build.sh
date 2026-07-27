#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Propeller"
# Bundle id kept from the Meeting Recorder era: changing it would reset
# TCC permissions (Microphone / Screen Recording) for existing users.
BUNDLE_ID="com.simplyai.meeting-recorder"
APP="/Applications/${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "=== Building Propeller (SPM) ==="

swift build -c release 2>&1

echo "=== Building .app bundle ==="

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"

# Embed Sparkle (SPM links @rpath/Sparkle.framework; add Frameworks rpath).
SPARKLE_FW=""
for candidate in \
    "$BUILD_DIR/Sparkle.framework" \
    ".build/arm64-apple-macosx/release/Sparkle.framework" \
    ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
do
    if [ -d "$candidate" ]; then
        SPARKLE_FW="$candidate"
        break
    fi
done
if [ -z "$SPARKLE_FW" ]; then
    echo "  ERROR: Sparkle.framework not found after build — cannot ship without updater"
    exit 1
fi
echo "  Embedding Sparkle from $SPARKLE_FW"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
# Prefer Frameworks over @loader_path next to the binary.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/MeetingRecorder" 2>/dev/null || true

# Menu bar template icon (PDF)
if [ -f "Resources/MenuBarIcon.pdf" ]; then
    cp "Resources/MenuBarIcon.pdf" "$APP/Contents/Resources/MenuBarIcon.pdf"
else
    echo "  WARNING: Resources/MenuBarIcon.pdf missing — menu bar falls back to SF Symbol"
fi

# Bundle gigastt sidecar binary (Phase 3)
GIGASTT_SRC="${GIGASTT_BIN:-}"
if [ -z "$GIGASTT_SRC" ]; then
    if [ -x "../../tools/gigastt/gigastt" ]; then
        GIGASTT_SRC="../../tools/gigastt/gigastt"
    elif [ -x "../tools/gigastt/gigastt" ]; then
        GIGASTT_SRC="../tools/gigastt/gigastt"
    elif [ -x "$HOME/Desktop/Propeller/tools/gigastt/gigastt" ]; then
        GIGASTT_SRC="$HOME/Desktop/Propeller/tools/gigastt/gigastt"
    fi
fi
if [ -n "$GIGASTT_SRC" ] && [ -x "$GIGASTT_SRC" ]; then
    echo "  Bundling gigastt from $GIGASTT_SRC"
    cp "$GIGASTT_SRC" "$APP/Contents/MacOS/gigastt"
    chmod +x "$APP/Contents/MacOS/gigastt"
else
    echo "  ERROR: gigastt binary not found — cannot ship without ASR sidecar"
    echo "  Place an executable at tools/gigastt/gigastt or set GIGASTT_BIN=/path/to/gigastt"
    exit 1
fi

# App icon: Icon Composer .icon → Assets.car (Liquid Glass) + .icns (fallback)
ICON_SRC=""
ICON_NAME="propellericon"
for candidate in \
    "../../propellericon.icon" \
    "../propellericon.icon" \
    "$HOME/Desktop/Propeller/propellericon.icon"
do
    if [ -d "$candidate" ]; then
        ICON_SRC="$candidate"
        break
    fi
done

ICON_PLIST_KEYS=""
if [ -n "$ICON_SRC" ]; then
    ICON_OUT="$BUILD_DIR/icon-compile"
    rm -rf "$ICON_OUT"
    mkdir -p "$ICON_OUT"
    echo "  Compiling icon from $ICON_SRC"
    # Include AccentColor.xcassets when present (Toggle on-tint; SO 79826801).
    ACTOOL_INPUTS=("$ICON_SRC")
    if [ -d "Resources/Assets.xcassets" ]; then
        ACTOOL_INPUTS+=("Resources/Assets.xcassets")
    fi
    if xcrun actool "${ACTOOL_INPUTS[@]}" \
        --app-icon "$ICON_NAME" \
        --compile "$ICON_OUT" \
        --output-partial-info-plist "$ICON_OUT/partial.plist" \
        --minimum-deployment-target 14.0 \
        --platform macosx \
        --target-device mac \
        --include-all-app-icons \
        --output-format human-readable-text >/dev/null
    then
        if [ -f "$ICON_OUT/Assets.car" ]; then
            cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
        fi
        if [ -f "$ICON_OUT/${ICON_NAME}.icns" ]; then
            cp "$ICON_OUT/${ICON_NAME}.icns" "$APP/Contents/Resources/${ICON_NAME}.icns"
        fi
        ICON_PLIST_KEYS=$(cat <<ICONPLIST
    <key>CFBundleIconFile</key>
    <string>${ICON_NAME}</string>
    <key>CFBundleIconName</key>
    <string>${ICON_NAME}</string>
ICONPLIST
)
    else
        echo "  WARNING: actool failed — falling back to AppIcon.icns if present"
    fi
fi

if [ -z "$ICON_PLIST_KEYS" ]; then
    if [ -f "../AppIcon.icns" ]; then
        cp "../AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    fi
    ICON_PLIST_KEYS=$(cat <<'ICONPLIST'
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
ICONPLIST
)
fi

# Sparkle auto-update (plan-v2 5.3). Public EdDSA key is committed; private stays in Keychain / sparkle/private/.
SU_PUBLIC_ED_KEY=""
if [ -f "sparkle/eddsa_pub.txt" ]; then
    SU_PUBLIC_ED_KEY=$(tr -d '[:space:]' < sparkle/eddsa_pub.txt)
fi
if [ -z "$SU_PUBLIC_ED_KEY" ]; then
    echo "  ERROR: sparkle/eddsa_pub.txt missing — run sparkle bin/generate_keys --account propeller -p"
    exit 1
fi
SU_FEED_URL="${SU_FEED_URL:-https://github.com/levalovushka/propeller/releases/latest/download/appcast.xml}"

# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.10</string>
    <key>CFBundleShortVersionString</key>
    <string>1.10</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
${ICON_PLIST_KEYS}
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- LSUIElement removed: the app launches with a window and dock icon.
         MainView toggles NSApp.activationPolicy between .regular (window open)
         and .accessory (window closed, menu-bar-only). -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Propeller needs microphone access to record your meetings.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Propeller captures meeting audio from Zoom and other apps so both sides of the call are recorded.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Propeller may use screen-audio capture as a fallback so both sides of video calls are recorded.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Propeller reads your calendar to show upcoming meetings and pre-fill titles and participants.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Propeller reads your calendar to show upcoming meetings and pre-fill titles and participants.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyDownloadsUpdates</key>
    <false/>
</dict>
</plist>
PLIST

# Optional TelemetryDeck App ID (dogfood analytics). Empty → Analytics bootstrap no-ops.
TELEMETRYDECK_APP_ID="${TELEMETRYDECK_APP_ID:-}"
if [ -n "$TELEMETRYDECK_APP_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :TelemetryDeckAppID string ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :TelemetryDeckAppID ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist"
    echo "  TelemetryDeck App ID embedded"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Entitlements
cat > "$BUILD_DIR/entitlements.plist" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

# Sign with entitlements.
# Prefer a local "MeetingRecorder Dev" certificate for stable signing (TCC permissions
# survive rebuilds). Falls back to ad-hoc if the cert doesn't exist.
# NOTE: no `-v` — a self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) and so
# wouldn't pass the "valid identities" filter, but codesign signs with it fine and
# the stable signature is what makes TCC (Mic/Screen/Calendar) survive rebuilds.
SIGN_IDENTITY="MeetingRecorder Dev"
SIGN_HASH=$(security find-identity -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    echo "  Signing with '$SIGN_IDENTITY' certificate (stable identity)"
    if [ -x "$APP/Contents/MacOS/gigastt" ]; then
        codesign --force --sign "$SIGN_HASH" \
            --entitlements "$BUILD_DIR/entitlements.plist" \
            "$APP/Contents/MacOS/gigastt"
    fi
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --deep --sign "$SIGN_HASH" \
            "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --deep --sign "$SIGN_HASH" \
        --entitlements "$BUILD_DIR/entitlements.plist" \
        "$APP"
else
    echo "  WARNING: '$SIGN_IDENTITY' not found — signing ad-hoc"
    echo "  TCC (Mic / Screen Recording / Calendar) will reset on every rebuild."
    echo "  Create a self-signed codesign identity named '$SIGN_IDENTITY' for stable local builds."
    if [ -x "$APP/Contents/MacOS/gigastt" ]; then
        codesign --force --sign - \
            --entitlements "$BUILD_DIR/entitlements.plist" \
            "$APP/Contents/MacOS/gigastt"
    fi
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --deep --sign - \
            "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --deep --sign - \
        --entitlements "$BUILD_DIR/entitlements.plist" \
        "$APP"
fi

xattr -cr "$APP"

echo ""
echo "=== Installed: $APP ==="
echo "Open from Spotlight or: open -a '${APP_NAME}'"
echo "DMG: ./package-dmg.sh  (after a successful ./build.sh)"
