#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Propeller"
# Bundle id kept from the Meeting Recorder era: changing it would reset
# TCC permissions (Microphone / Screen Recording) for existing users.
BUNDLE_ID="com.simplyai.meeting-recorder"
APP="/Applications/${APP_NAME}.app"
BUILD_DIR=".build/release"

# --gallery builds the state gallery in (screenshots / redesign reference).
# Never pass it for anything a user will run: the gallery can pose the pipeline
# in any state. Without the flag not a byte of it is compiled.
SWIFT_FLAGS=()
APP_VARIANT=""
for arg in "$@"; do
    case "$arg" in
        --gallery)
            SWIFT_FLAGS+=(-Xswiftc -DGALLERY)
            APP_VARIANT=" + state gallery"
            ;;
    esac
done

echo "=== Building Propeller (SPM)${APP_VARIANT} ==="

swift build -c release "${SWIFT_FLAGS[@]}" 2>&1

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

# Bundle GigaAM ASR weights (~247 MB, INT8 set only).
# Shipping these removes the whole first-run ASR download: no progress bar to
# strand on a flaky link, no disk gate, and transcription works offline from
# the first launch. The FP32 encoder (885 MB) is deliberately NOT bundled --
# gigastt loads the INT8 one and only checks the FP32 filename for existence,
# which GigasttSidecar satisfies with a zero-byte marker.
MODELS_SRC=""
for candidate in "../../tools/gigastt/models-e2e" "../tools/gigastt/models-e2e" "$HOME/Desktop/Propeller/tools/gigastt/models-e2e"; do
    if [ -d "$candidate" ]; then MODELS_SRC="$candidate"; break; fi
done
MODEL_FILES="v3_e2e_rnnt_encoder_int8.onnx v3_e2e_rnnt_decoder.onnx v3_e2e_rnnt_joint.onnx v3_e2e_rnnt_vocab.txt wespeaker_resnet34.onnx"
if [ -n "$MODELS_SRC" ]; then
    MODELS_DST="$APP/Contents/Resources/gigastt-models"
    mkdir -p "$MODELS_DST"
    missing=""
    for f in $MODEL_FILES; do
        if [ -f "$MODELS_SRC/$f" ]; then cp "$MODELS_SRC/$f" "$MODELS_DST/$f"; else missing="$missing $f"; fi
    done
    if [ -n "$missing" ]; then
        echo "  ERROR: GigaAM model files missing from $MODELS_SRC:$missing"
        echo "  Fetch them with: tools/gigastt/gigastt download --prequantized --model-variant e2e_rnnt --model-dir tools/gigastt/models-e2e"
        exit 1
    fi
    echo "  Bundling GigaAM INT8 models from $MODELS_SRC ($(du -sh "$MODELS_DST" | cut -f1))"
else
    echo "  ERROR: tools/gigastt/models-e2e not found -- cannot ship without ASR weights"
    exit 1
fi

# Bundle Ollama engine tarball (~140 MB compressed). Model (~5 GB) still downloads on demand.
OLLAMA_TGZ="${OLLAMA_TGZ:-}"
OLLAMA_TAG="v0.32.4"
OLLAMA_CACHE="../../tools/ollama/ollama-darwin-${OLLAMA_TAG}.tgz"
OLLAMA_URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_TAG}/ollama-darwin.tgz"
if [ -z "$OLLAMA_TGZ" ]; then
    if [ -f "$OLLAMA_CACHE" ]; then
        OLLAMA_TGZ="$OLLAMA_CACHE"
    elif [ -f "../tools/ollama/ollama-darwin-${OLLAMA_TAG}.tgz" ]; then
        OLLAMA_TGZ="../tools/ollama/ollama-darwin-${OLLAMA_TAG}.tgz"
    fi
fi
if [ -z "$OLLAMA_TGZ" ] || [ ! -f "$OLLAMA_TGZ" ]; then
    echo "  Fetching Ollama ${OLLAMA_TAG} tarball for DMG…"
    mkdir -p "$(dirname "$OLLAMA_CACHE")"
    curl -L --fail --progress-bar -o "$OLLAMA_CACHE" "$OLLAMA_URL"
    OLLAMA_TGZ="$OLLAMA_CACHE"
fi
echo "  Bundling Ollama engine from $OLLAMA_TGZ"
cp "$OLLAMA_TGZ" "$APP/Contents/Resources/ollama-darwin.tgz"

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
    <string>1.13.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.13.1</string>
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

# TelemetryDeck App ID — always embed for dogfood (Analytics.swift has the same constant).
TELEMETRYDECK_APP_ID="${TELEMETRYDECK_APP_ID:-FD2E1040-C134-4F44-BCAC-76441E1662D7}"
/usr/libexec/PlistBuddy -c "Add :TelemetryDeckAppID string ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TelemetryDeckAppID ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist"
echo "  TelemetryDeck App ID embedded (${TELEMETRYDECK_APP_ID:0:8}…)"

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
