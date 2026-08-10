#!/usr/bin/env bash
# Measure the live layer and diff against baseline (companion to measure-batch.sh).
#
# Runs in real time by construction: one pass costs as long as the fixture's
# audio, because the cost of a live transcript is 20 frame deliveries a second
# for the length of a meeting, not throughput on a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="$ROOT/swift"
K="${K:-1}"
PORT="${PORT:-9877}"
cd "$SWIFT"

if pgrep -qf "Propeller.app/Contents/MacOS/MeetingRecorder"; then
  echo "WARNING: Propeller is running. Its sidecar is not measured, but it shares"
  echo "         the CPU — quit it before taking a baseline."
  echo
fi

echo "== Building Bench (release) =="
swift build -c release --product Bench

echo "== Running live harness -k $K on port $PORT =="
swift run -c release Bench -- --live -k "$K" --port "$PORT" "$@"

echo "== Diff vs baseline =="
if [[ -f benchmarks/baseline.json ]]; then
  "$ROOT/tools/bench-diff"
else
  echo "No benchmarks/baseline.json yet."
  echo "After a trusted run on a quiet machine:"
  echo "  cp benchmarks/latest.json benchmarks/baseline.json"
fi
