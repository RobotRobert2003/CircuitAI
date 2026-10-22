#!/usr/bin/env bash
# D-221. Separate exact regression tests from optional serial component timing.
# Run PERF_BENCH=1 only after game and compiler processes have finished.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
BENCHMARKS="${CIRCUIT_BENCHMARK_REPO:-$REPO/../CircuitAI.benchmarks}"
OUT="${PERF_OUT:-$BENCHMARKS/build-theatres/d221/validation}"
mkdir -p "$OUT"
IMAGE=ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest
MSYS2_ARG_CONV_EXCL='*' docker run --rm --pull=never \
  -v "$REPO:/src:ro" -v "$OUT:/out" --entrypoint bash "$IMAGE" -c '
set -euo pipefail
for test in ranged_geometry_test ranged_performance_benchmark; do
  x86_64-w64-mingw32-g++ -std=c++20 -O2 -Wall -Wextra -static \
    -I/src/src/circuit /src/tests/$test.cpp -o /out/$test.exe
done
'
"$OUT/ranged_geometry_test.exe"
if [[ "${PERF_BENCH:-0}" == 1 ]]; then
  "$OUT/ranged_performance_benchmark.exe"
fi
