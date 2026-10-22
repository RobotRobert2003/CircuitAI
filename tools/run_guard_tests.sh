#!/usr/bin/env bash
# D-223: real CUnitAPI callback adapter against the pinned read-only Recoil ABI.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -W)"
ENGINE="${ENGINE_ROOT:-$REPO/../bar-RecoilEngine}"
BENCHMARKS="${CIRCUIT_BENCHMARK_REPO:-$REPO/../CircuitAI.benchmarks}"
OUT="${GUARD_OUT:-$BENCHMARKS/build-theatres/d223/tests}"
mkdir -p "$OUT"
MSYS2_ARG_CONV_EXCL='*' docker run --rm -v "$REPO:/src:ro" -v "$ENGINE:/engine:ro" -v "$OUT:/out" --entrypoint sh ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest -c '
set -eu
x86_64-w64-mingw32-g++-posix -std=c++20 -O2 -Wall -Wextra -static -I/src/src/circuit -I/engine/rts -I/engine/rts/lib -I/engine/rts/ExternalAI/Interface -I/engine/AI/Wrappers/Cpp/src -I/build/mingwlibs64/include /src/tests/guard_callback_test.cpp /src/src/circuit/spring/SpringUnit.cpp -o /out/guard_callback_test.exe
'
"$OUT/guard_callback_test.exe"
