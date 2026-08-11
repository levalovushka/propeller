#!/usr/bin/env bash
# Prepare the Ollama engine tarball for bundling, without what this app can never
# use.
#
# The official darwin release is 139 MB compressed, 464 MB unpacked, and 349 MB of
# that is the MLX runtime plus 18 MB of Intel CPU backends. Our summaries do not
# touch either: the engine itself logs `using llama-server for model` for
# qwen3.5:4b, and the app is arm64-only, so `libggml-cpu-*.so` (haswell, zen4,
# skylakex …) cannot load on any machine we ship to. Result: 139 → 34 MB in the
# bundle, 464 → 97 MB on the user's disk.
#
# What this deliberately does NOT change: how the engine is installed. The
# tarball still ships inside the .app and is still unpacked from there on first
# use, with no new branch and no network. That matters more than the megabytes —
# the first-run path in this project has been broken by downloads before
# (STATE.md: the "85 %" hang), and a slimmer archive cannot introduce that class
# of failure.
#
# Ollama does not support this officially (ollama/ollama#7419 asks for smaller
# release artifacts and is unresolved), so the check below is not a formality:
# every time `releaseTag` moves, re-run this and generate a summary before
# shipping. MLX already handles Q4_K_M models in preview, which is the very
# quantisation we use — the day it starts claiming them, this trade expires.
set -euo pipefail

TAG="${OLLAMA_TAG:-v0.32.4}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_DIR="$ROOT/tools/ollama"
FULL="$CACHE_DIR/ollama-darwin-$TAG.tgz"
SLIM="$CACHE_DIR/ollama-darwin-$TAG-slim.tgz"
URL="https://github.com/ollama/ollama/releases/download/$TAG/ollama-darwin.tgz"

mkdir -p "$CACHE_DIR"

if [ ! -f "$FULL" ]; then
  echo "Fetching the official $TAG tarball…"
  curl -L --fail --progress-bar -o "$FULL" "$URL"
fi

# Everything the engine needs to serve a GGUF model through llama-server. If a
# future release renames these, the guard below fails loudly instead of shipping
# an engine that cannot start.
REQUIRED=(ollama llama-server)

for name in "${REQUIRED[@]}"; do
  if ! tar -tzf "$FULL" | grep -qx "$name"; then
    echo "ERROR: '$name' is not in $FULL — the release layout changed." >&2
    echo "       Re-read what the archive contains before slimming it." >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$FULL" -C "$WORK"

before_unpacked="$(du -sm "$WORK" | cut -f1)"

# The MLX runtime: an alternative inference engine for Apple Silicon. Ollama picks
# llama-server for our model, so none of this is ever read.
rm -rf "$WORK"/mlx_metal_v*
# CPU backends for x86 microarchitectures. The app is arm64-only.
rm -f "$WORK"/libggml-cpu-*.so

after_unpacked="$(du -sm "$WORK" | cut -f1)"

rm -f "$SLIM"
( cd "$WORK" && tar -czf "$SLIM" * )

for name in "${REQUIRED[@]}"; do
  if ! tar -tzf "$SLIM" | grep -qx "$name"; then
    echo "ERROR: '$name' vanished while slimming — refusing to write a broken archive." >&2
    rm -f "$SLIM"
    exit 1
  fi
done

full_mb=$(( $(stat -f%z "$FULL") / 1048576 ))
slim_mb=$(( $(stat -f%z "$SLIM") / 1048576 ))

echo
echo "Wrote $SLIM"
echo "  archive:  ${full_mb} MB → ${slim_mb} MB"
echo "  unpacked: ${before_unpacked} MB → ${after_unpacked} MB"
echo
echo "Before shipping this, generate one summary end to end. The engine must log"
echo "'using llama-server for model'; if it ever logs MLX instead, this archive is"
echo "no longer safe and the full one has to go back."
