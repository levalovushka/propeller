#!/bin/bash
# Build appcast.xml + delta updates for the latest DMG in ../../dist (Sparkle / plan-v2 5.3).
#
# Why deltas: the bundle is 331 MB, and 282 MB of the DMG never changes between releases —
# 247 MB of ASR weights, a 34 MB Ollama tarball, a 27 MB engine binary. Only the 15 MB app
# binary moves. Measured on the three shipped 1.16.x images:
#
#   Propeller1.16.7-1.16.6.delta   1 062 706 B   (1,0 MB)
#   Propeller1.16.7-1.16.5.delta   2 138 074 B   (2,0 MB)
#   Propeller-1.16.7-….dmg       282 517 594 B   (282 MB)
#
# Delta updates also stop the disk from carrying the weights twice. The app clones the
# bundled weights into Application Support (GigasttSidecar.seedModelsFromBundle), and on APFS
# that clone shares blocks with the bundle — measured: copying 200 MB with FileManager costs
# ~0 bytes of free space. A *full* DMG update writes a second, unrelated copy of the same
# 247 MB and the clone keeps the old blocks alive; applying a delta clones every unchanged
# file instead, so the shared blocks survive. Measured: applying the 1.16.6→1.16.7 delta
# produced a complete 331 MB bundle for 51 MB of real disk.
#
# Nothing here is trusted on faith: unless VERIFY_DELTAS=0, every generated patch is applied
# to the old bundle it claims to patch and the result is compared file-by-file (sha256, mode,
# symlink target) against the app that actually ships in this release, then re-checked with
# codesign and stapler. A release cannot be published from this script without that passing.
set -euo pipefail
cd "$(dirname "$0")"

DIST="${DMG_OUT:-../../dist}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
PRIV_KEY="${SPARKLE_PRIVATE_KEY_FILE:-sparkle/private/eddsa_priv.key}"
FEED_BASE="${SU_DOWNLOAD_BASE:-https://github.com/levalovushka/propeller/releases/latest/download}"
# generate_appcast writes the feed *and* the patches into the archives directory, and moves
# archives it considers superseded into old_updates/ inside it. dist/ holds things it must not
# touch (the stable Propeller.dmg alias, release notes, the previous feed), so it gets its own
# directory, rebuilt from scratch on every run — a stale link in here would sign the wrong
# bytes into a delta.
ARCHIVES="$DIST/sparkle-archives"
MAX_DELTAS="${MAX_DELTAS:-5}"
VERIFY_DELTAS="${VERIFY_DELTAS:-1}"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ] || [ ! -x "$SPARKLE_BIN/BinaryDelta" ]; then
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

# The DMG above is just "newest file in dist/". generate_appcast reads the version out of the
# bundle inside each image, so it can no longer mislabel someone else's bytes — but this script
# still has to know *which* image is this release, to pick its release notes and to verify its
# patches. dist/ keeps every past release, so the name is checked against the installed app the
# same way package-dmg.sh names it (see its lines ~62-67).
if [ "$VERSION" = "$BUILD" ]; then
    EXPECTED_PREFIX="Propeller-${VERSION}-"
else
    EXPECTED_PREFIX="Propeller-${VERSION}+${BUILD}-"
fi
case "$DMG_NAME" in
    "${EXPECTED_PREFIX}"*.dmg) ;;
    *)
        echo "ERROR: picked $DMG_NAME but /Applications/Propeller.app is version ${VERSION} (build ${BUILD})."
        echo "Expected a name matching ${EXPECTED_PREFIX}*.dmg — rebuild/repackage this version first."
        exit 1
        ;;
esac

echo "=== Staging archives for ${DMG_NAME} ==="
rm -rf "$ARCHIVES"
mkdir -p "$ARCHIVES"

# This release plus the MAX_DELTAS newest older images: one patch is built per older image, and
# anyone whose version is not among them simply gets the full DMG (Sparkle falls back on its
# own when no matching delta is offered). Names carry no spaces — package-dmg.sh builds them
# from a version and a date — so `ls -t` output is safe to walk word by word here.
# The stable `Propeller.dmg` alias has no hyphen after the app name and cannot match this glob.
STAGED=0
for src in $(ls -t "$DIST"/Propeller-*.dmg | head -n $((MAX_DELTAS + 1))); do
    # Hard link: the images are ~282 MB each and both directories are on the same volume, so
    # this costs nothing. A copy would cost gigabytes per release.
    ln "$src" "$ARCHIVES/$(basename "$src")" 2>/dev/null || cp "$src" "$ARCHIVES/"
    STAGED=$((STAGED + 1))
done
echo "  $STAGED image(s): $(ls "$ARCHIVES" | tr '\n' ' ')"

# Release notes travel *inside* the feed. Sparkle 2.9 renders markdown (macOS 12+, our floor is
# 14.4), and generate_appcast picks up a notes file named exactly like the archive it belongs to.
# Without this the update window is a blank panel — which is what every release before 1.16.7
# showed.
NOTES_SRC="$DIST/RELEASE-${VERSION}-NOTES.md"
if [ -f "$NOTES_SRC" ]; then
    cp "$NOTES_SRC" "$ARCHIVES/${DMG_NAME%.dmg}.md"
    echo "  Release notes: $(basename "$NOTES_SRC") → embedded"
else
    echo "  WARNING: $NOTES_SRC not found — the update window will have no release notes."
fi

echo "=== Generating appcast + deltas ==="
# --maximum-versions 1: the feed keeps only the current release. Older items would carry
# enclosure URLs under releases/latest/download/, and those assets live in *their own* release,
# so every historical item would be a dead link. Sparkle only ever needs the newest item, and
# the patches for older versions hang off it.
"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$PRIV_KEY" \
    --download-url-prefix "${FEED_BASE}/" \
    --maximum-versions 1 \
    --maximum-deltas "$MAX_DELTAS" \
    --embed-release-notes \
    "$ARCHIVES"

DELTAS=()
while IFS= read -r line; do DELTAS+=("$line"); done < <(ls "$ARCHIVES"/*.delta 2>/dev/null || true)

if [ ${#DELTAS[@]} -eq 0 ]; then
    echo "  WARNING: no deltas generated — every client will download the full ${DMG_NAME}."
fi

# --- Verification -------------------------------------------------------------------------
# A patch that produces a bundle differing from the shipped one by a single byte is a broken
# app on someone's Mac, and the appcast has no way to notice. So each patch is applied here for
# real and its output compared against the image we are about to publish.
mounts=()
scratch=""
cleanup_verify() {
    for m in ${mounts[@]+"${mounts[@]}"}; do hdiutil detach "$m" -quiet -force 2>/dev/null || true; done
    [ -n "$scratch" ] && rm -rf "$scratch"
}

# Files, permissions, symlink targets. Content alone is not enough: a lost exec bit on
# Contents/MacOS/gigastt is a build that records and never transcribes.
manifest() {
    local root="$1"
    ( cd "$root" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | sort -k2 )
    ( cd "$root" && find . -type f -print0 | sort -z | xargs -0 stat -f 'mode %Lp %N' | sort -k3 )
    ( cd "$root" && find . -type l -print0 | sort -z | xargs -0 -I{} sh -c 'printf "link %s -> %s\n" "{}" "$(readlink "{}")"' | sort )
    ( cd "$root" && find . -type d | sort | sed 's/^/dir /' )
}

extract_app() {
    local dmg="$1" dest="$2" mnt
    mnt=$(mktemp -d /tmp/propeller-verify-XXXXXX)
    hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mnt" -quiet
    mounts+=("$mnt")
    ditto "$mnt/Propeller.app" "$dest"
    hdiutil detach "$mnt" -quiet -force
    rmdir "$mnt" 2>/dev/null || true
}

if [ "$VERIFY_DELTAS" = "1" ] && [ ${#DELTAS[@]} -gt 0 ]; then
    echo "=== Verifying ${#DELTAS[@]} delta(s) against ${DMG_NAME} ==="
    trap cleanup_verify EXIT
    scratch=$(mktemp -d /tmp/propeller-delta-verify-XXXXXX)
    extract_app "$DMG" "$scratch/new.app"
    manifest "$scratch/new.app" > "$scratch/new.manifest"

    for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do
        base=$(basename "$delta" .delta)     # Propeller1.16.7-1.16.6
        from="${base##*-}"                   # 1.16.6
        matches=("$DIST"/Propeller-"${from}"[-+]*.dmg)
        if [ ! -f "${matches[0]}" ] || [ ${#matches[@]} -ne 1 ]; then
            echo "  ERROR: cannot find exactly one image for version ${from} in $DIST"
            exit 1
        fi
        old_dmg="${matches[0]}"
        echo "  ${from} → ${VERSION} ($(basename "$delta"), $(du -h "$delta" | cut -f1))"

        rm -rf "$scratch/old.app" "$scratch/patched.app"
        extract_app "$old_dmg" "$scratch/old.app"
        "$SPARKLE_BIN/BinaryDelta" apply "$scratch/old.app" "$scratch/patched.app" "$delta"

        manifest "$scratch/patched.app" > "$scratch/patched.manifest"
        if ! diff -q "$scratch/patched.manifest" "$scratch/new.manifest" >/dev/null; then
            echo "  ERROR: patched bundle differs from the shipped ${VERSION} bundle:"
            diff "$scratch/patched.manifest" "$scratch/new.manifest" | head -20
            exit 1
        fi
        # Count sha256 lines only — 'dir …' lines start with a hex digit too.
        echo "    bundle identical to the shipped one ($(grep -c '^[0-9a-f]\{64\} ' "$scratch/new.manifest") files hashed)"

        # The patch rewrites files inside a signed bundle. If it got the seal wrong, this is
        # where it shows up — not on a person's Mac at launch.
        codesign --verify --deep --strict "$scratch/patched.app" 2>/dev/null \
            || { echo "  ERROR: codesign rejects the patched bundle"; exit 1; }
        xcrun stapler validate "$scratch/patched.app" >/dev/null 2>&1 \
            || { echo "  ERROR: the patched bundle carries no notarization ticket"; exit 1; }
        echo "    codesign: valid, notarization ticket: present"
        rm -rf "$scratch/old.app" "$scratch/patched.app"
    done
    cleanup_verify
    trap - EXIT
    scratch=""
    echo "  All deltas verified."
elif [ ${#DELTAS[@]} -gt 0 ]; then
    echo "=== VERIFY_DELTAS=0: patches were NOT applied or checked — do not ship this ==="
fi

# --- Publish set --------------------------------------------------------------------------
cp "$ARCHIVES/appcast.xml" "$DIST/appcast.xml"
for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do cp "$delta" "$DIST/"; done

# The stable alias is package-dmg.sh's, not ours, but it ships in the same release and the
# site's download button is the thing that breaks when it is missing — so it is checked here,
# where the upload list is printed, rather than discovered by a failing `gh release upload`.
STABLE="$DIST/Propeller.dmg"
UPLOAD=("$DMG" "$DIST/appcast.xml")
if [ -f "$STABLE" ]; then
    UPLOAD+=("$STABLE")
else
    echo ""
    echo "WARNING: $STABLE is missing — run ./package-dmg.sh, which hard-links it next to the"
    echo "         versioned image. The site's Download button points at that name; a release"
    echo "         without it leaves the landing page serving the previous version."
fi
for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do UPLOAD+=("$DIST/$(basename "$delta")"); done

echo ""
echo "=== Appcast: $DIST/appcast.xml ==="
echo "Upload every one of these to the v${VERSION} release, names unchanged:"
for f in "${UPLOAD[@]}"; do echo "  $f"; done
echo ""
echo "  gh release upload v${VERSION} \\"
printf '   '; for f in "${UPLOAD[@]}"; do printf ' "%s"' "$f"; done; echo ""
echo ""
echo "Then check the release is the one Sparkle will read — the feed lives at"
echo "releases/latest/download/, so a draft or a pre-release leaves everybody on the old"
echo "version while looking published:"
echo ""
echo "  curl -sL ${FEED_BASE}/appcast.xml | grep -E 'shortVersionString|deltaFrom'"
for delta in ${DELTAS[@]+"${DELTAS[@]}"}; do
    echo "  curl -s -o /dev/null -w '%{http_code} %{url_effective}\\n' -IL ${FEED_BASE}/$(basename "$delta")"
done
echo ""
echo "Asset names must match the enclosure URLs in the feed exactly — Sparkle fetches them"
echo "from ${FEED_BASE}/. A missing .delta is not fatal (clients fall back to the full image),"
echo "a *renamed* one is: the download 404s and the update fails."
if [ ! -f "$ARCHIVES/${DMG_NAME%.dmg}.md" ]; then
    echo ""
    echo "REMINDER: this feed carries no release notes — the update window will be an empty"
    echo "          panel. Write $NOTES_SRC and run this script again."
fi
echo ""
echo "Extraction cache: ~/Library/Caches/Sparkle_generate_appcast (~1 GB, generate_appcast's"
echo "own, safe to delete; keeping it makes the next run faster)."
