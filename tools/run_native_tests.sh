#!/usr/bin/env bash
# D-094: compile and run the standalone native unit tests (tests/*_test.cpp)
# with the Recoil build container's MinGW compiler, then run the executables on
# the Windows host. Exit 0 when every test passes.
#
#   bash tools/run_native_tests.sh
#
# The tests include only engine-free headers (BaseLayoutGeometry.h,
# LayoutRanking.h), so no engine, wrapper or AI build is needed.
set -u
REPO="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
OUT="${TMPDIR:-${TEMP:-/tmp}}/circuit-native-tests"
mkdir -p "$OUT"
IMAGE="${CIRCUIT_TEST_IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep recoil-build-amd64-windows | grep -v ':<none>$' | head -1)}"
# A digest-pinned pull has no tag (<none>); fall back to the image ID.
if [ -z "$IMAGE" ]; then
	IMAGE="$(docker images --format '{{.Repository}} {{.ID}}' | awk '/recoil-build-amd64-windows/ {print $2; exit}')"
fi
if [ -z "$IMAGE" ]; then
	echo "run_native_tests: the recoil-build-amd64-windows image is not present (run a docker build once)" >&2
	exit 2
fi
tests=(mex_navigation_test transport_definition_test commander_combat_test callback_buffer_test resurrection_claim_test reservation_claim_test task_reference_test dormant_task_chain_test economy_index_test route_command_test reservation_candidates_test construction_recovery_test guard_command_test target_preference_test layout_ranking_test base_layout_geometry_test allied_reservations_test local_reservations_test lane_solver_test strategic_targeting_test terrain_route_test air_geometry_test metal_field_test enemy_reclaim_policy_test naval_geometry_test air_safety_test widget_state_test ranged_geometry_test ground_cohort_test local_rush_test water_survey_test field_analysis_test)
cmd=""
for t in "${tests[@]}"; do
    extra=""
    if [ "$t" = lane_solver_test ] || [ "$t" = terrain_route_test ]; then extra="/src/src/circuit/terrain/LaneSolver.cpp"; fi
    if [ "$t" = field_analysis_test ]; then extra="/src/src/circuit/terrain/field/FieldAnalysis.cpp /src/src/circuit/terrain/field/FieldEncode.cpp"; fi
	cmd="$cmd x86_64-w64-mingw32-g++ -std=c++20 -O1 -Wall -Wextra -static -pthread -I/src/src -I/src/src/circuit -I/src/src/lib /src/tests/$t.cpp $extra -o /out/$t.exe || exit 1;"
done
cmd="$cmd x86_64-w64-mingw32-g++ -std=c++20 -O1 -static -DAS_MAX_PORTABILITY -DANGELSCRIPT_EXPORT -I/src/src/lib/angelscript/include -I/src/src/lib/angelscript/add_on/scriptarray -I/src/src/lib/angelscript/add_on/scriptstdstring -I/src/src/lib/angelscript/add_on/scriptdictionary /src/tests/production_math_test.cpp /src/src/lib/angelscript/add_on/scriptarray/scriptarray.cpp /src/src/lib/angelscript/add_on/scriptstdstring/scriptstdstring.cpp /src/src/lib/angelscript/add_on/scriptstdstring/scriptstdstring_utils.cpp /src/src/lib/angelscript/add_on/scriptdictionary/scriptdictionary.cpp /src/src/lib/angelscript/source/*.cpp -o /out/production_math_test.exe || exit 1;"
cmd="$cmd x86_64-w64-mingw32-g++ -std=c++20 -O1 -static -DAS_MAX_PORTABILITY -DANGELSCRIPT_EXPORT -I/src/src/circuit -I/src/src/lib /src/tests/task_reference_vm_test.cpp /src/src/lib/angelscript/source/*.cpp -o /out/task_reference_vm_test.exe || exit 1;"
MSYS2_ARG_CONV_EXCL='*' docker run --rm -v "$REPO:/src:ro" -v "$(cd "$OUT" && { pwd -W 2>/dev/null || pwd; }):/out" --entrypoint sh "$IMAGE" -c "$cmd" || { echo "run_native_tests: compile failed" >&2; exit 1; }
rc=0
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/geothermal_math.as" "$REPO/tests/geothermal_math_tests.as" || rc=1
"$OUT/task_reference_vm_test.exe" || rc=1
for t in "${tests[@]}"; do
	if ! "$OUT/$t.exe"; then
		echo "run_native_tests: $t FAILED" >&2
		rc=1
	fi
done
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/production_math.as" "$REPO/tests/production_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/placement_math.as" "$REPO/tests/placement_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/amphibious_math.as" "$REPO/tests/amphibious_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/air_math.as" "$REPO/tests/air_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/air_perimeter_math.as" "$REPO/tests/air_perimeter_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/build_power_math.as" "$REPO/tests/build_power_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/metal_math.as" "$REPO/tests/metal_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/team_share_math.as" "$REPO/tests/team_share_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/systems/team/commander_energy.as" "$REPO/tests/commander_energy_tests.as" --strings || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/sea_math.as" "$REPO/tests/sea_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/recovery_math.as" "$REPO/tests/recovery_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/sea_coast_math.as" "$REPO/tests/sea_coast_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/land_siege_math.as" "$REPO/tests/land_siege_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/spam_math.as" "$REPO/tests/spam_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/nuke_math.as" "$REPO/tests/nuke_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/heavy_rush_math.as" "$REPO/tests/heavy_rush_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/tech_economy_math.as" "$REPO/tests/tech_economy_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/gantry_math.as" "$REPO/tests/gantry_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/assist_math.as" "$REPO/tests/assist_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/transport_math.as" "$REPO/tests/transport_math_tests.as" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/math/scout_raid_math.as" "$REPO/tests/scout_raid_math_tests.as" || rc=1
"${PYTHON:-python}" "$REPO/tools/knowledge/check_performance_policy.py" --runner "$OUT/production_math_test.exe" --output "$OUT/performance-policy" || rc=1
"${PYTHON:-python}" "$REPO/tools/knowledge/check_weapon_work.py" --runner "$OUT/production_math_test.exe" --output "$OUT/weapon-policy" || rc=1
"$OUT/production_math_test.exe" "$REPO/data/script/src/helpers/common/collection_helpers.as" "$REPO/tests/collection_helpers_tests.as" --dictionary || rc=1
exit $rc
