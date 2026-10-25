#!/usr/bin/env bash
# D-094 / D-369: compile and run the standalone native unit tests (tests/*_test.cpp)
# and the AngelScript helper suites (tests/*_tests.as, run by production_math_test
# through the bundled AngelScript engine). Exit 0 when every test passes.
#
#   bash tools/run_native_tests.sh               # cross-compile in the Recoil Windows build
#                                                # container, run the .exe files on this host
#   bash tools/run_native_tests.sh --host        # compile with the host's g++ ($CXX) and run
#                                                # here: the Linux CI runner (pr-checks.yml)
#   bash tools/run_native_tests.sh --only cpp    # the C++ tests only
#   bash tools/run_native_tests.sh --only as     # the AngelScript suites only
#
# The tests include only engine-free headers (BaseLayoutGeometry.h, LayoutRanking.h
# and the like), so no engine, wrapper or AI build is needed. The AngelScript suites
# compile the vendored AngelScript engine once (AS_MAX_PORTABILITY, so no JIT).
set -u
MODE=docker
ONLY=all
while [ $# -gt 0 ]; do
	case "$1" in
		--host) MODE=host ;;
		--only) ONLY="$2"; shift ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "run_native_tests: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
case "$ONLY" in all|cpp|as) ;; *) echo "run_native_tests: --only takes cpp or as" >&2; exit 2 ;; esac

REPO="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
# python for the two policy checkers: $PYTHON, else python, else python3 (Windows ships a
# python3 alias stub that only opens the Store; Linux runners may have python3 only)
PY="${PYTHON:-python}"
"$PY" --version > /dev/null 2>&1 || PY=python3
OUT="${TMPDIR:-${TEMP:-/tmp}}/circuit-native-tests"
mkdir -p "$OUT"

# The C++ tests, each a single translation unit, plus the extra sources a few need.
tests=(mex_navigation_test mex_territory_test transport_definition_test commander_combat_test callback_buffer_test resurrection_claim_test reservation_claim_test task_reference_test dormant_task_chain_test economy_index_test route_command_test reservation_candidates_test construction_recovery_test guard_command_test target_preference_test layout_ranking_test base_layout_geometry_test allied_reservations_test local_reservations_test lane_solver_test lane_raster_test strategic_targeting_test terrain_route_test air_geometry_test metal_field_test enemy_reclaim_policy_test naval_geometry_test air_safety_test widget_state_test ranged_geometry_test ground_cohort_test local_rush_test water_survey_test field_analysis_test)
extra_sources() {
	case "$1" in
		lane_solver_test|terrain_route_test) echo "src/circuit/terrain/LaneSolver.cpp" ;;
		field_analysis_test) echo "src/circuit/terrain/field/FieldAnalysis.cpp src/circuit/terrain/field/FieldCorridors.cpp src/circuit/terrain/field/FieldEncode.cpp src/circuit/terrain/field/FieldLandmarks.cpp src/circuit/terrain/field/FieldSettings.cpp src/lib/json/jsoncpp.cpp" ;;
	esac
}
# The AngelScript suites: policy script, its tests, runner flags.
as_suites=(
	"data/script/src/helpers/math/geothermal_math.as tests/geothermal_math_tests.as"
	"data/script/src/helpers/math/production_math.as tests/production_math_tests.as"
	"data/script/src/helpers/math/placement_math.as tests/placement_math_tests.as"
	"data/script/src/helpers/math/amphibious_math.as tests/amphibious_math_tests.as"
	"data/script/src/helpers/math/air_math.as tests/air_math_tests.as"
	"data/script/src/helpers/math/air_perimeter_math.as tests/air_perimeter_math_tests.as"
	"data/script/src/helpers/math/build_power_math.as tests/build_power_math_tests.as"
	"data/script/src/helpers/math/metal_math.as tests/metal_math_tests.as"
	"data/script/src/helpers/math/team_share_math.as tests/team_share_math_tests.as"
	"data/script/src/systems/team/commander_energy.as tests/commander_energy_tests.as --strings"
	"data/script/src/helpers/math/sea_math.as tests/sea_math_tests.as"
	"data/script/src/systems/team/sea_tech.as tests/sea_tech_tests.as --strings"
	"data/script/src/helpers/math/recovery_math.as tests/recovery_math_tests.as"
	"data/script/src/helpers/math/sea_coast_math.as tests/sea_coast_math_tests.as"
	"data/script/src/helpers/math/land_siege_math.as tests/land_siege_math_tests.as"
	"data/script/src/helpers/math/spam_math.as tests/spam_math_tests.as"
	"data/script/src/helpers/math/nuke_math.as tests/nuke_math_tests.as"
	"data/script/src/helpers/math/heavy_rush_math.as tests/heavy_rush_math_tests.as"
	"data/script/src/helpers/math/tech_economy_math.as tests/tech_economy_math_tests.as"
	"data/script/src/helpers/math/gantry_math.as tests/gantry_math_tests.as"
	"data/script/src/helpers/math/assist_math.as tests/assist_math_tests.as"
	"data/script/src/helpers/math/transport_math.as tests/transport_math_tests.as"
	"data/script/src/helpers/math/scout_raid_math.as tests/scout_raid_math_tests.as"
	"data/script/src/helpers/common/collection_helpers.as tests/collection_helpers_tests.as --dictionary"
)

# ---------------------------------------------------------------- compile
# Every compile command is written against $SRC (the repo) and $BIN (the output
# directory); the two modes differ only in compiler, link flags and paths.
if [ "$MODE" = docker ]; then
	IMAGE="${CIRCUIT_TEST_IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep recoil-build-amd64-windows | grep -v ':<none>$' | head -1)}"
	# A digest-pinned pull has no tag (<none>); fall back to the image ID.
	if [ -z "$IMAGE" ]; then
		IMAGE="$(docker images --format '{{.Repository}} {{.ID}}' | awk '/recoil-build-amd64-windows/ {print $2; exit}')"
	fi
	if [ -z "$IMAGE" ]; then
		echo "run_native_tests: the recoil-build-amd64-windows image is not present (run a docker build once, or use --host)" >&2
		exit 2
	fi
	CXXBIN="x86_64-w64-mingw32-g++"
	LINK="-static -pthread"
	EXT=".exe"
	SRC="/src"
	BIN="/out"
else
	CXXBIN="${CXX:-g++}"
	LINK="-pthread"
	EXT=""
	SRC="$REPO"
	BIN="$OUT"
fi
commands=()
if [ "$ONLY" != as ]; then
	for t in "${tests[@]}"; do
		extra=""
		for e in $(extra_sources "$t"); do extra="$extra $SRC/$e"; done
		commands+=("$CXXBIN -std=c++20 -O1 -Wall -Wextra $LINK -I$SRC/src -I$SRC/src/circuit -I$SRC/src/lib $SRC/tests/$t.cpp$extra -o $BIN/$t$EXT")
	done
fi
if [ "$ONLY" != cpp ]; then
	AS="-DAS_MAX_PORTABILITY -DANGELSCRIPT_EXPORT"
	commands+=("$CXXBIN -std=c++20 -O1 $LINK $AS -I$SRC/src/lib/angelscript/include -I$SRC/src/lib/angelscript/add_on/scriptarray -I$SRC/src/lib/angelscript/add_on/scriptstdstring -I$SRC/src/lib/angelscript/add_on/scriptdictionary $SRC/tests/production_math_test.cpp $SRC/src/lib/angelscript/add_on/scriptarray/scriptarray.cpp $SRC/src/lib/angelscript/add_on/scriptstdstring/scriptstdstring.cpp $SRC/src/lib/angelscript/add_on/scriptstdstring/scriptstdstring_utils.cpp $SRC/src/lib/angelscript/add_on/scriptdictionary/scriptdictionary.cpp $SRC/src/lib/angelscript/source/*.cpp -o $BIN/production_math_test$EXT")
	commands+=("$CXXBIN -std=c++20 -O1 $LINK $AS -I$SRC/src/circuit -I$SRC/src/lib $SRC/tests/task_reference_vm_test.cpp $SRC/src/lib/angelscript/source/*.cpp -o $BIN/task_reference_vm_test$EXT")
fi
echo "run_native_tests: compiling ${#commands[@]} test binaries ($MODE, --only $ONLY)"
if [ "$MODE" = docker ]; then
	cmd=""
	for c in "${commands[@]}"; do cmd="$cmd $c || exit 1;"; done
	MSYS2_ARG_CONV_EXCL='*' docker run --rm -v "$REPO:/src:ro" -v "$(cd "$OUT" && { pwd -W 2>/dev/null || pwd; }):/out" --entrypoint sh "$IMAGE" -c "$cmd" || { echo "run_native_tests: compile failed" >&2; exit 1; }
else
	jobs="$(nproc 2>/dev/null || echo 2)"
	printf '%s\n' "${commands[@]}" | xargs -P "$jobs" -I{} sh -c '{} || { echo "COMPILE FAILED: {}" >&2; exit 255; }' || { echo "run_native_tests: compile failed" >&2; exit 1; }
fi

# ---------------------------------------------------------------- run
passed=0
failed=0
failures=()
run() {   # run <label> <command...>
	local label="$1"; shift
	if "$@"; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		failures+=("$label")
		echo "run_native_tests: $label FAILED" >&2
	fi
}
if [ "$ONLY" != cpp ]; then
	run "task_reference_vm_test" "$OUT/task_reference_vm_test$EXT"
	for suite in "${as_suites[@]}"; do
		# shellcheck disable=SC2086
		set -- $suite
		run "$2" "$OUT/production_math_test$EXT" "$REPO/$1" "$REPO/$2" "${@:3}"
	done
	run "check_performance_policy" "$PY" "$REPO/tools/knowledge/check_performance_policy.py" --runner "$OUT/production_math_test$EXT" --output "$OUT/performance-policy"
	run "check_weapon_work" "$PY" "$REPO/tools/knowledge/check_weapon_work.py" --runner "$OUT/production_math_test$EXT" --output "$OUT/weapon-policy"
fi
if [ "$ONLY" != as ]; then
	for t in "${tests[@]}"; do
		run "$t" "$OUT/$t$EXT"
	done
fi
echo "run_native_tests: $passed passed, $failed failed (--only $ONLY)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "| Suite | Passed | Failed |"
		echo "|---|---|---|"
		echo "| $([ "$ONLY" = cpp ] && echo 'C++ tests' || { [ "$ONLY" = as ] && echo 'AngelScript suites' || echo 'C++ tests and AngelScript suites'; }) | $passed | $failed |"
		for f in "${failures[@]}"; do echo "- failed: \`$f\`"; done
	} >> "$GITHUB_STEP_SUMMARY"
fi
[ "$failed" -eq 0 ]
