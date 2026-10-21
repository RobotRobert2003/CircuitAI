void test_base_centre_blocks() { Check(PlacementMath::FootprintIntersectsCircle(100, 200, 8, 8, 100, 200, 1200)); }
void test_outside_circle_allows() { Check(!PlacementMath::FootprintIntersectsCircle(1309, 200, 8, 8, 100, 200, 1200)); }
void test_touching_boundary_blocks() { Check(PlacementMath::FootprintIntersectsCircle(1308, 200, 8, 8, 100, 200, 1200)); }
void test_centre_outside_but_footprint_inside_blocks() { Check(PlacementMath::FootprintIntersectsCircle(1304, 200, 8, 8, 100, 200, 1200)); }
void test_diagonal_circle_is_not_bounding_square() { Check(!PlacementMath::FootprintIntersectsCircle(1000, 1000, 8, 8, 0, 0, 1200)); }
void test_rectangle_corner_intersection_blocks() { Check(PlacementMath::FootprintIntersectsCircle(730, 1000, 10, 40, 0, 0, 1200)); }
void test_ally_base_blocks_outside_own_base() { Check(!PlacementMath::FootprintIntersectsCircle(3000, 0, 8, 8, 0, 0, 1200) && PlacementMath::FootprintIntersectsCircle(3000, 0, 8, 8, 3100, 0, 1200)); }
void test_negative_direction_is_symmetric() { Check(PlacementMath::FootprintIntersectsCircle(-1208, 0, 8, 8, 0, 0, 1200) && !PlacementMath::FootprintIntersectsCircle(-1209, 0, 8, 8, 0, 0, 1200)); }
void test_long_line_crossing_base_blocks() { Check(PlacementMath::FootprintIntersectsCircle(1600, 0, 496, 16, 0, 0, 1200)); }
void test_invalid_extents_fail_closed() { Check(PlacementMath::FootprintIntersectsCircle(5000, 0, -1, 8, 0, 0, 1200)); }
void test_territory_nearer_allies_admitted() { Check(PlacementMath::FriendlyTerritory(100, 101)); }
void test_territory_equal_frontier_not_defensive() { Check(!PlacementMath::FriendlyTerritory(100, 100)); }
void test_territory_nearer_enemy_rejected() { Check(!PlacementMath::FriendlyTerritory(101, 100)); }
void test_territory_invalid_distance_rejected() { Check(!PlacementMath::FriendlyTerritory(-1, 100)); }
void test_coverage_own_core_retained_at_boundary() { Check(PlacementMath::CoversCore(2000, 1200 * 1200, 800)); }
void test_coverage_center_inside_but_core_exposed_rejected() { Check(!PlacementMath::CoversCore(2000, 1201 * 1201, 800)); }
void test_coverage_neighbour_close_enough_included() { Check(PlacementMath::CoversCore(2000, 900 * 900, 800)); }
void test_coverage_distant_neighbour_cannot_be_promised() { Check(!PlacementMath::CoversCore(2000, 2500 * 2500, 800)); }
void test_coverage_missing_interceptor_rejected() { Check(!PlacementMath::CoversCore(0, 0, 800)); }
void test_coverage_core_larger_than_range_rejected() { Check(!PlacementMath::CoversCore(700, 0, 800)); }
void test_build_snap_even_footprint_crosses_lane_boundary() {
    const float snapped = PlacementMath::SnapBuildCoordinate(3519.0f, 2);
    Check(snapped == 3520.0f && int(3519.0f / 64.0f) == 54 && int(snapped / 64.0f) == 55);
}
void test_build_snap_even_footprint_rounding_edge() {
    Check(PlacementMath::SnapBuildCoordinate(3511.0f, 2) == 3504.0f);
    Check(PlacementMath::SnapBuildCoordinate(3512.0f, 2) == 3520.0f);
}
void test_build_snap_odd_footprint_offset() {
    Check(PlacementMath::SnapBuildCoordinate(3519.0f, 1) == 3512.0f);
    Check(PlacementMath::SnapBuildCoordinate(3520.0f, 3) == 3528.0f);
}
void test_build_snap_is_idempotent() {
    for (int footprint = 1; footprint <= 8; ++footprint) {
        for (int coordinate = 0; coordinate < 4096; ++coordinate) {
            const float snapped = PlacementMath::SnapBuildCoordinate(float(coordinate), footprint);
            Check(PlacementMath::SnapBuildCoordinate(snapped, footprint) == snapped);
        }
    }
}
void test_build_snap_rejects_invalid_input() {
    Check(PlacementMath::SnapBuildCoordinate(-1.0f, 2) < 0.0f);
    Check(PlacementMath::SnapBuildCoordinate(100.0f, 0) < 0.0f);
}
void test_build_snap_lane_rejection_leaves_alternate_candidate() {
    array<float> candidates = {3519.0f, 3471.0f};
    float accepted = -1.0f;
    for (uint i = 0; i < candidates.length(); ++i) {
        const float snapped = PlacementMath::SnapBuildCoordinate(candidates[i], 2);
        if (int(snapped / 64.0f) == 55) continue;
        accepted = snapped;
        break;
    }
    Check(accepted == 3472.0f);
}
