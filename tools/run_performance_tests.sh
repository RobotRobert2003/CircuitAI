#!/usr/bin/env bash
# D-199 focused differential tests / microbenchmarks. Requires the existing
# native build cache (the pinned VM object files) and read-only engine checkout.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -W)"
ENGINE="${ENGINE_ROOT:-$REPO/../bar-RecoilEngine}"
BENCHMARKS="${CIRCUIT_BENCHMARK_REPO:-$REPO/../CircuitAI.benchmarks}"
OUT="${PERF_OUT:-$BENCHMARKS/build-theatres/d199/validation}"
mkdir -p "$OUT"
IMAGE=ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest
MSYS2_ARG_CONV_EXCL='*' docker run --rm -v "$REPO:/src:ro" -v "$ENGINE:/engine:ro" -v "$BENCHMARKS/build-theatres/native-cache:/cache:ro" -v "$OUT:/out" --entrypoint bash "$IMAGE" -c '
set -euo pipefail
CXX=x86_64-w64-mingw32-g++-posix
$CXX -std=c++20 -O3 -DNDEBUG -static -I/src/src /src/tests/local_reservations_benchmark.cpp -o /out/local_reservations_benchmark.exe
$CXX -std=c++20 -O2 -Wall -static -I/src/src/circuit -I/cache/AI/Wrappers/Cpp/src-generated -I/engine/AI/Wrappers/Cpp/src -I/engine/rts /src/tests/custom_command_test.cpp /src/src/circuit/spring/CustomCommand.cpp /engine/AI/Wrappers/Cpp/src/AIException.cpp /engine/AI/Wrappers/Cpp/src/CallbackAIException.cpp -o /out/custom_command_test.exe
$CXX -std=c++20 -O2 -static -pthread -I/src/src/lib/angelscript/include -I/src/src/lib/angelscript/add_on/scriptarray /src/tests/production_math_test.cpp /cache/AI/Skirmish/BARb/CMakeFiles/BARb.dir/src/lib/angelscript/source/*.cpp.obj /cache/AI/Skirmish/BARb/CMakeFiles/BARb.dir/src/lib/angelscript/add_on/scriptarray/scriptarray.cpp.obj -o /out/policy_test.exe
'
"$OUT/custom_command_test.exe"
"${PYTHON:-python}" "$REPO/tools/knowledge/check_performance_policy.py" --runner "$OUT/policy_test.exe" --output "$OUT/policy"
"${PYTHON:-python}" "$REPO/tools/knowledge/check_weapon_work.py" --runner "$OUT/policy_test.exe" --output "$OUT/weapon-policy"
# Run these only when other game/build processes are stopped; their times are
# local microbenchmarks, not engine FPS or network-throughput measurements.
if [[ "${PERF_BENCH:-0}" == 1 ]]; then
    "$OUT/local_reservations_benchmark.exe"
    "${PYTHON:-python}" "$REPO/tools/knowledge/check_performance_policy.py" --runner "$OUT/policy_test.exe" --output "$OUT/bench-policy" --benchmark
    "${PYTHON:-python}" "$REPO/tools/knowledge/check_weapon_work.py" --runner "$OUT/policy_test.exe" --output "$OUT/bench-weapon" --benchmark
fi
