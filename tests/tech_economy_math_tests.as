void test_full_metal_releases_reactor_even_with_full_energy_and_pending_conversion() {
    Check(EcoPlanner::DecideConversion(true,true,1,2,true,true,true,true,false) == EcoPlanner::METAL_FULL);
}
void test_recovery_income_exception_requires_lost_capacity_and_full_funding() {
    Check(EcoPlanner::ReplacementFunded(1,0,500,500));
    Check(!EcoPlanner::ReplacementFunded(0,0,5000,500));
    Check(!EcoPlanner::ReplacementFunded(1,0,499,500));
    Check(!EcoPlanner::ReplacementFunded(1,1,5000,500));
    Check(!EcoPlanner::ReplacementFunded(2,1,999,500));
    Check(EcoPlanner::ReplacementFunded(2,1,1000,500));
    Check(!EcoPlanner::ReplacementFunded(1,0,500,0));
}
void test_saturated_installed_capacity_releases_first_reactor_without_air_worker() {
    Check(EcoPlanner::DecideConversion(false,true,0,2,false,true,true,true,false) == EcoPlanner::CAPACITY);
}
void test_pending_converter_retains_its_supply_commitment() {
    Check(EcoPlanner::DecideConversion(false,true,1,2,false,true,true,true,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,2,2,true,true,true,true,false) == EcoPlanner::PENDING);
}
void test_failed_placement_releases_reactor_but_success_remains_eligible() {
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,true,true) == EcoPlanner::PLACEMENT);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,true,false) == EcoPlanner::READY);
}
void test_missing_capped_unbuildable_and_income_gated_conversion_cannot_hold_reactor() {
    Check(EcoPlanner::DecideConversion(false,false,0,2,true,true,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,false,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,false,true,false) == EcoPlanner::UNBUILDABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,false,false) == EcoPlanner::INCOME);
}

void test_disabled_parallelism_is_not_a_phantom_pending_task() {
    Check(EcoPlanner::DecideConversion(false,true,0,0,true,true,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,1,0,true,true,true,true,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,1,2,true,true,true,false,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,1,2,true,true,true,true,false) == EcoPlanner::READY);
}
void test_compact_assist_target_reaches_each_step_at_half_income() {
    Check(TechEconomyMath::FastAssistTarget(22.49f, 2.0f, false, 10) == 0);
    Check(TechEconomyMath::FastAssistTarget(22.5f, 2.0f, false, 10) == 5);
    Check(TechEconomyMath::FastAssistTarget(44.99f, 2.0f, false, 10) == 5);
    Check(TechEconomyMath::FastAssistTarget(45.0f, 2.0f, false, 10) == 10);
}
void test_compact_assist_target_retains_rush_and_owner_caps() {
    Check(TechEconomyMath::FastAssistTarget(45.0f, 2.0f, true, 10) == 2);
    Check(TechEconomyMath::FastAssistTarget(10000.0f, 2.0f, false, 10) == 10);
    Check(TechEconomyMath::FastAssistTarget(45.0f, 2.0f, false, 7) == 7);
    Check(TechEconomyMath::FastAssistTarget(45.0f, 2.0f, true, 1) == 1);
}
void test_standard_assist_target_matches_previous_policy() {
    // Sweep through both income branches and threshold edges; the noncompact
    // maps must keep exactly the prior target, including opening rush limits.
    for (int sample = 0; sample <= 800; ++sample) {
        const float income = float(sample) * 0.25f;
        for (int rush = 0; rush < 2; ++rush) {
            int previous = income < 100.0f ? 5 * int(income / 45.0f) : 5 * int(income / 20.0f);
            if (rush != 0 && previous > 2) previous = 2;
            if (previous > 10) previous = 10;
            Check(TechEconomyMath::FastAssistTarget(income, 1.0f, rush != 0, 10) == previous);
        }
    }
}
