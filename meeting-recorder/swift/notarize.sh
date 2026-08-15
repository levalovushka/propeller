#!/bin/bash
# Notarize and staple one artifact — a .app bundle or a .dmg.
#
# Both get notarized on a release, and the order matters: the .app first (so the ticket
# travels inside the bundle Sparkle unpacks), then the DMG built around that stapled app.
# Stapling the DMG alone is not enough — a Sparkle update replaces the app without the
# image, and a first launch with no network would then have nothing local to check.
#
#   ./build.sh
#   ./notarize.sh                       # defaults to /Applications/Propeller.app
#   ./package-dmg.sh                    # signs + notarizes the image itself
#
# Credentials live in the keychain, never here:
#   xcrun notarytool store-credentials propbuild --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-/Applications/Propeller.app}"
PROFILE="${NOTARY_PROFILE:-propbuild}"

if [ ! -e "$TARGET" ]; then
    echo "ERROR: $TARGET not found."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "ERROR: no notarytool credentials for profile '$PROFILE'."
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id <team-id>"
    exit 1
fi

# Refuse to submit something the notary service will reject anyway. Ad-hoc and self-signed
# builds are the normal local case (see build.sh's identity ladder), and the failure comes
# back ten minutes later as a log URL instead of immediately as this line.
# The signature is read into a variable rather than piped into grep: `grep -q` exits on the
# first match and closes the pipe, codesign dies of SIGPIPE, and `pipefail` reports the whole
# pipeline as failed — so a correctly signed image was rejected here as unsigned.
SIG_INFO=$(codesign -dv --verbose=4 "$TARGET" 2>&1 || true)
case "$SIG_INFO" in
    *"Developer ID Application"*) ;;
    *)
        echo "ERROR: $TARGET is not signed with Developer ID Application — notarization would fail."
        echo "  Re-run ./build.sh with the Developer ID certificate in the keychain."
        exit 1
        ;;
esac

case "$TARGET" in
    *.dmg)
        SUBMIT="$TARGET"
        SPCTL_TYPE="install"
        CLEANUP=""
        ;;
    *)
        # notarytool takes an archive, not a bundle. `ditto -c -k --keepParent` is the form
        # Apple documents: a plain `zip` mangles symlinks inside Sparkle.framework/Versions.
        SUBMIT=$(mktemp -d)/$(basename "$TARGET").zip
        CLEANUP=$(dirname "$SUBMIT")
        SPCTL_TYPE="exec"
        echo "=== Archiving $TARGET ==="
        ditto -c -k --keepParent "$TARGET" "$SUBMIT"
        ;;
esac
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

echo "=== Submitting $(basename "$SUBMIT") ($(du -h "$SUBMIT" | cut -f1)) ==="
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait

# The ticket is stapled to the original, never to the zip: the zip is only transport.
echo "=== Stapling $TARGET ==="
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# What a person downloading this actually gets asked. `codesign --verify` passing says
# nothing about Gatekeeper — an unnotarized build passes it too.
echo "=== Gatekeeper ==="
spctl -a -vvv -t "$SPCTL_TYPE" "$TARGET"
