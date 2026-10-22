void test_gantry_survives_last_lab_reclaim() {
    Check(GantryMath::ClusterEligible(true, true, false, true, false));
    Check(!GantryMath::ClusterEligible(true, true, false, false, false));
    Check(!GantryMath::ClusterEligible(true, false, false, true, false));
    Check(!GantryMath::ClusterEligible(false, true, false, true, false));
    Check(GantryMath::ClusterEligible(false, false, false, false, true));
}
void test_zero_turret_fallback_requires_funding_and_no_productive_worker() {
    Check(GantryMath::CanFallback(300, 0, 90, false, false, true, true));
    Check(!GantryMath::CanFallback(80, 0, 90, false, false, true, true));
    Check(!GantryMath::CanFallback(300, 0, 90, true, false, true, true));
    Check(!GantryMath::CanFallback(300, 0, 90, false, true, true, true));
    Check(!GantryMath::CanFallback(300, 0, 90, false, false, false, true));
    Check(!GantryMath::CanFallback(300, 0, 90, false, false, true, false));
    Check(!GantryMath::CanFallback(300, 0, 0, false, false, true, true));
    Check(!GantryMath::CanFallback(300, 290, 90, false, false, true, true));
}
void test_early_gantry_preserves_nuclear_and_heavy_commitments() {
    Check(GantryMath::CanStart(true, true, 200, 200, false, false, true, 100, 100));
    Check(!GantryMath::CanStart(false, true, 200, 200, false, false, true, 100, 100));
    Check(!GantryMath::CanStart(true, false, 200, 200, false, false, true, 100, 100));
    Check(!GantryMath::CanStart(true, true, 199, 200, false, false, true, 100, 100));
    Check(!GantryMath::CanStart(true, true, 200, 200, true, false, true, 100, 100));
    Check(!GantryMath::CanStart(true, true, 200, 200, false, true, true, 100, 100));
    Check(!GantryMath::CanStart(true, true, 200, 200, false, false, false, 100, 100));
    Check(!GantryMath::CanStart(true, true, 200, 200, false, false, true, 99, 100));
}
void test_income_window_time_weighted_irregular_cadence() {
    GantryMath::IncomeWindow window;
    window.Push(0, 100, 10, 10);
    window.Push(2, 200, 10, 10);
    window.Push(10, 1000, 10, 10);
    Check(window.Ready(10, 10));
    Check(window.Mean() == 180); // 2*100 + 8*200, not the sample mean
    window.Push(12, 400, 10, 10);
    Check(window.Mean() == 360);
    Check(!window.Ready(23, 10));
}
void test_income_window_wrap_duplicate_reset_and_reference_equivalence() {
    GantryMath::IncomeWindow window;
    for (int frame = 0; frame < 1000; ++frame) {
        window.Push(frame, float(frame % 7), 10, 2);
        window.Push(frame, float(frame % 7), 10, 2); // same frame does not double-count
        if (frame < 10) { Check(!window.Ready(frame, 2)); continue; }
        float reference = 0;
        for (int previous = frame - 10; previous < frame; ++previous) reference += float(previous % 7);
        Check(window.Mean() - reference / 10.0f < 0.0001f && window.Mean() - reference / 10.0f > -0.0001f);
        Check(window.count <= 11);
    }
    window.Push(1200, 500, 10, 2);
    Check(!window.Ready(1200, 2));
    window.Push(100, 500, 10, 2);
    Check(!window.Ready(100, 2));
    window.Push(101, 500, 20, 2);
    Check(!window.Ready(101, 2));
}

void test_income_window_invalid_configuration_does_not_retain_admission() {
    GantryMath::IncomeWindow window;
    window.Push(0, 400, 10, 10);
    window.Push(10, 400, 10, 10);
    Check(window.Ready(10, 10));
    window.Push(11, 400, 0, 10);
    Check(!window.Ready(11, 10));
    window.Push(12, 400, 10, 10);
    Check(!window.Ready(12, 10));
    window.Push(22, 400, 10, 10);
    Check(window.Ready(22, 10));
}

// 100,000 updates exceed 16 AIs * 1 h / the host's ~1 s economy cadence.
// These benchmark incremental policy cost, not game FPS or network traffic.
void bench_gantry_income_window_100000_updates() {
    GantryMath::IncomeWindow window;
    for (int index = 0; index < 100000; ++index) {
        window.Push(index * 32, float(index % 400), 300, 60);
        if (index > 10) Check(window.Ready(index * 32, 60));
    }
    Check(window.count <= 11);
}
void bench_gantry_admission_100000_queries() {
    for (int index = 0; index < 100000; ++index)
        Check(GantryMath::CanStart(true, true, 240, 200, false, false, true, 180, 100));
}

void test_admission_provenance_does_not_exempt_gifts_or_other_factories() {
    Check(GantryMath::AdmittedProduct(true, true, 17, 17, 301, 300));
    Check(!GantryMath::AdmittedProduct(false, true, 17, 17, 301, 300));
    Check(!GantryMath::AdmittedProduct(true, false, 17, 17, 301, 300));
    Check(!GantryMath::AdmittedProduct(true, true, -1, -1, 301, 300));
    Check(!GantryMath::AdmittedProduct(true, true, 18, 17, 301, 300));
    Check(!GantryMath::AdmittedProduct(true, true, 17, 17, 299, 300));
    Check(!GantryMath::AdmittedProduct(true, true, 17, 17, -1, 300));
    Check(!GantryMath::AdmittedProduct(true, true, 17, 17, 301, -1));
}
