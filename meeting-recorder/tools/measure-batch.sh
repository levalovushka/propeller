#!/usr/bin/env bash
# Run the batch harness and diff against baseline (plan-testing-metrics M2/M3).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="$ROOT/swift"
K="${K:-1}"
cd "$SWIFT"
echo "== Building Bench (release) =="
swift build -c release --product Bench
echo "== Running Bench -k $K =="
swift run -c release Bench -- -k "$K" "$@"
echo "== Diff vs baseline =="
if [[ -f benchmarks/baseline.json ]]; then
  "$ROOT/tools/bench-diff"
else
  echo "No benchmarks/baseline.json yet."
  echo "After a trusted run on the reference machine:"
  echo "  cp benchmarks/latest.json benchmarks/baseline.json"
fi
