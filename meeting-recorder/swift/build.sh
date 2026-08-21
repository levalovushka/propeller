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

# Inputs are resolved and checked BEFORE anything is destroyed. `rm -rf "$APP"`
# below deletes the installed app and rebuilds in place, so a failure after that
# line leaves a person without a working Propeller — and a missing engine binary
# would only show up later, as a summary that never arrives.
OLLAMA_TGZ="${OLLAMA_TGZ:-}"
OLLAMA_TAG="v0.32.4"
OLLAMA_SLIM="../../tools/ollama/ollama-darwin-${OLLAMA_TAG}-slim.tgz"
OLLAMA_CACHE="../../tools/ollama/ollama-darwin-${OLLAMA_TAG}.tgz"
if [ -z "$OLLAMA_TGZ" ]; then
    # Slimmed archive first (34 MB instead of 139 — see tools/slim-ollama.sh),
    # then the official one, then whatever a dev put in ../tools.
    for candidate in "$OLLAMA_SLIM" "$OLLAMA_CACHE" \
                     "../tools/ollama/ollama-darwin-${OLLAMA_TAG}.tgz"; do
        if [ -f "$candidate" ]; then OLLAMA_TGZ="$candidate"; break; fi
    done
fi
if [ -z "$OLLAMA_TGZ" ] || [ ! -f "$OLLAMA_TGZ" ]; then
    echo "  Preparing Ollama ${OLLAMA_TAG} tarball…"
    ../tools/slim-ollama.sh
    OLLAMA_TGZ="$OLLAMA_SLIM"
fi
for required in ollama llama-server; do
    if ! tar -tzf "$OLLAMA_TGZ" | grep -qx "$required"; then
        echo "  ERROR: '$required' missing from $OLLAMA_TGZ"
        echo "         Refusing to build: an engine that cannot serve turns into a summary"
        echo "         that never arrives, with nothing in the interface to explain why."
        echo "         Rebuild it with tools/slim-ollama.sh, or set OLLAMA_TGZ to the official release."
        exit 1
    fi
done

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

# Metal shaders. SwiftPM does not compile .metal — it reports them as unhandled
# files and walks past — so the library is built here and read from the app's
# resources (`SummaryShader`). Without it the text shimmer falls back to a
# gradient. Summary reveal is SwiftUI-only (fade + rise) and needs no metallib.
SHADERS=(PropellerUI/TextShimmer.metal PropellerUI/Disintegrate.metal)
if xcrun --find metal >/dev/null 2>&1; then
    AIR_DIR="$(mktemp -d)"
    AIRS=()
    SHADER_OK=1
    for src in "${SHADERS[@]}"; do
        air="$AIR_DIR/$(basename "$src" .metal).air"
        if xcrun -sdk macosx metal -O -c "$src" -o "$air" 2>/dev/null; then
            AIRS+=("$air")
        else
            SHADER_OK=0
            break
        fi
    done
    if [ "$SHADER_OK" -eq 1 ] &&
       xcrun -sdk macosx metallib "${AIRS[@]}" -o "$APP/Contents/Resources/PropellerShaders.metallib"; then
        echo "  Shaders: PropellerShaders.metallib (${#AIRS[@]} sources)"
    else
        echo "  WARNING: shader build failed — text shimmer uses gradient fallback"
    fi
else
    echo "  WARNING: no Metal toolchain — text shimmer uses gradient fallback"
fi

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

# MCP server for Claude Desktop. A second executable in MacOS/, launched by
# Claude rather than by us — which is exactly why it is a binary and not a mode
# of the app: it has to run with Propeller closed. Its absolute path goes into
# claude_desktop_config.json, and Sparkle replaces the whole bundle, so the path
# a person's config points at stays valid across updates.
if [ -x "$BUILD_DIR/PropellerMCP" ]; then
    cp "$BUILD_DIR/PropellerMCP" "$APP/Contents/MacOS/PropellerMCP"
    chmod +x "$APP/Contents/MacOS/PropellerMCP"
    echo "  Bundling PropellerMCP (read-only MCP server)"
else
    echo "  ERROR: PropellerMCP not found in $BUILD_DIR — the Claude connection would be"
    echo "         a button that writes a config pointing at a binary that is not there."
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

# The engine tarball itself. Resolved and validated at the top of this script,
# before the installed bundle is deleted; the model (~3.4 GB) still downloads on
# demand.
echo "  Bundling Ollama engine from $OLLAMA_TGZ ($(( $(stat -f%z "$OLLAMA_TGZ") / 1048576 )) MB)"
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
        --minimum-deployment-target 14.4 \
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
    <string>1.16.7</string>
    <key>CFBundleShortVersionString</key>
    <string>1.16.7</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
${ICON_PLIST_KEYS}
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <!-- LSUIElement removed: the app launches with a window and dock icon.
         MainView toggles NSApp.activationPolicy between .regular (window open)
         and .accessory (window closed, menu-bar-only). -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Propeller needs microphone access to record your meetings.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Propeller captures meeting audio from Zoom and other apps so both sides of the call are recorded.</string>
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
    <!-- Sparkle's default is a day, and its floor is an hour. A day is the wrong
         number for us: 1.13 shipped a defect that broke every meeting longer than
         25 minutes, the fix existed four hours later, and the people carrying it
         had no way to learn that. An hour costs one HEAD request against the
         GitHub feed. -->
    <key>SUScheduledCheckInterval</key>
    <integer>3600</integer>
    <!-- The key is SUAutomaticallyUpdate, and it has to be spelled exactly that:
         SUConstants.m:38 maps it, SPUUpdaterSettings.m:327 reads it, and nothing in
         Sparkle ever looks up "SUAutomaticallyDownloadsUpdates" — which is what stood
         here until 1.16.8 and therefore decided nothing at all.

         True means Sparkle fetches the update in the background and installs it the
         next time the app quits (SPUUpdaterDelegate.h:420 — "Sparkle will always
         attempt to install the update when the app terminates"). Nothing is replaced
         under a running app, so a meeting being recorded cannot be interrupted by it,
         and nobody has to sit through a progress bar: the download is 1-2 MB now that
         the feed carries delta patches. Someone whose version is older than the
         patches in the feed still pulls the whole 282 MB image in the background — the
         reason make-appcast.sh keeps five patches rather than one.

         This is the initial value only. Sparkle persists a user's own choice in
         defaults and reads that first; there is no switch for it in Settings, because
         "how updates arrive" is not a decision we want to hand someone. -->
    <key>SUAutomaticallyUpdate</key>
    <true/>
</dict>
</plist>
PLIST

# TelemetryDeck App ID — always embed for dogfood (Analytics.swift has the same constant).
TELEMETRYDECK_APP_ID="${TELEMETRYDECK_APP_ID:-FD2E1040-C134-4F44-BCAC-76441E1662D7}"
/usr/libexec/PlistBuddy -c "Add :TelemetryDeckAppID string ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :TelemetryDeckAppID ${TELEMETRYDECK_APP_ID}" "$APP/Contents/Info.plist"
echo "  TelemetryDeck App ID embedded (${TELEMETRYDECK_APP_ID:0:8}…)"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Entitlements. Two files, not one: the ASR binary records, the app also reads the
# calendar, and an entitlement on a process that has no use for it is a permission
# handed out for nothing (same reason PropellerMCP is signed without any).
#
# `com.apple.security.personal-information.calendars` is not optional under the
# hardened runtime, which this script turns on for notarization: TCC refuses to
# even prompt without it, and refuses **silently**. That is what happened between
# 2026-08-15 and 08-20 — the notarized build asked for calendar access, tccd
# answered «denied» without a window, названия встреч стал придумывать LLM, and
# nothing in the app or in System Settings said a word:
#
#   tccd: Prompting policy for hardened runtime; service: kTCCServiceCalendar
#   requires entitlement com.apple.security.personal-information.calendars but it
#   is missing for accessing={com.simplyai.meeting-recorder}
#
# Adding a TCC-backed API to the app means adding its entitlement here in the same
# breath. The usage-description key in Info.plist is not enough on its own.
cat > "$BUILD_DIR/entitlements-app.plist" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
ENT

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

# Extended attributes are stripped BEFORE signing, not after: `xattr -cr` rewrites files the
# signature seals over, so doing it last quietly invalidates the seal on resources.
xattr -cr "$APP"

# Sign inside out — nested code first, the bundle last. `--deep` is gone on purpose: it stamps
# the app's entitlements onto Sparkle's XPC services and cannot carry per-target options, and
# that combination is what the notary service rejects.
#
# Identity ladder:
#   1. "Developer ID Application" — the shipping one. Adds the hardened runtime and a secure
#      timestamp, both mandatory for notarization (see notarize.sh).
#   2. "MeetingRecorder Dev" — self-signed and untrusted, but a *stable* identity, so TCC
#      (Mic / Calendar) survives rebuilds. Local development only, never shippable.
#   3. ad-hoc — TCC resets on every rebuild.
# NOTE on 2: no `-v` in that lookup — a self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED)
# and so is filtered out of "valid identities", yet codesign signs with it fine.
SIGN_OPTS=()
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
    echo "  Signing with Developer ID Application (hardened runtime + secure timestamp)"
    SIGN_OPTS=(--options runtime --timestamp)
else
    SIGN_HASH=$(security find-identity -p codesigning 2>/dev/null | grep "MeetingRecorder Dev" | head -1 | awk '{print $2}')
    if [ -n "$SIGN_HASH" ]; then
        echo "  Signing with 'MeetingRecorder Dev' (stable local identity — not shippable)"
    else
        echo "  WARNING: no signing identity found — signing ad-hoc"
        echo "  TCC (Mic / Calendar) will reset on every rebuild."
        SIGN_HASH="-"
    fi
fi

sign_target() {
    codesign --force --sign "$SIGN_HASH" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} "$@"
}

# Sparkle's own signing order: services, helper, updater app, then the framework itself.
# The version directory is resolved rather than hardcoded ("B" today) — and "Current" is
# skipped deliberately, codesign wants the concrete directory, not the symlink.
SPARKLE_V=$(ls -d "$APP/Contents/Frameworks/Sparkle.framework/Versions"/[A-Z] 2>/dev/null | head -1)
if [ -n "$SPARKLE_V" ]; then
    for target in \
        "$SPARKLE_V/XPCServices/Downloader.xpc" \
        "$SPARKLE_V/XPCServices/Installer.xpc" \
        "$SPARKLE_V/Autoupdate" \
        "$SPARKLE_V/Updater.app"
    do
        if [ -e "$target" ]; then
            sign_target "$target"
        fi
    done
    sign_target "$APP/Contents/Frameworks/Sparkle.framework"
fi

if [ -x "$APP/Contents/MacOS/gigastt" ]; then
    sign_target --entitlements "$BUILD_DIR/entitlements.plist" "$APP/Contents/MacOS/gigastt"
fi
# No entitlements on the MCP server, deliberately: it reads files and speaks
# JSON on a pipe. The audio-input entitlement would be a permission the binary
# has no use for, on a process someone else launches.
if [ -x "$APP/Contents/MacOS/PropellerMCP" ]; then
    sign_target "$APP/Contents/MacOS/PropellerMCP"
fi
sign_target --entitlements "$BUILD_DIR/entitlements-app.plist" "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

echo ""
echo "=== Installed: $APP ==="
echo "Open from Spotlight or: open -a '${APP_NAME}'"
echo "DMG: ./package-dmg.sh  (after a successful ./build.sh)"
