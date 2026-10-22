void test_income_target_is_bounded_and_handles_disabled_settings() {
    Check(AssistMath::TargetCount(39, 40, 20, 10) == 0);
    Check(AssistMath::TargetCount(40, 40, 20, 10) == 2);
    Check(AssistMath::TargetCount(200, 40, 20, 10) == 10);
    Check(AssistMath::TargetCount(1e30f, 40, 20, 10) == 10);
    Check(AssistMath::TargetCount(200, 40, 0, 10) == 0);
    Check(AssistMath::TargetCount(200, 40, 20, 0) == 0);
}
void test_donated_full_bank_can_fund_power_despite_current_deficit() {
    Check(AssistMath::CanRecruit(1, 0, 4, true, false, true, false));
    Check(!AssistMath::CanRecruit(1, 0, 4, true, false, false, false));
    Check(AssistMath::CanRecruit(1, 0, 4, true, true, false, false));
}
void test_pending_frames_and_other_factories_cannot_duplicate_assist_orders() {
    Check(!AssistMath::CanRecruit(1, 1, 4, true, true, true, false));
    Check(!AssistMath::CanRecruit(4, 0, 4, true, true, true, false));
    Check(!AssistMath::CanRecruit(5, 0, 4, true, true, true, false));
    Check(AssistMath::CanRecruit(3, 0, 4, true, true, true, false));
}
void test_power_does_not_preempt_combat_or_energy_recovery() {
    Check(!AssistMath::CanRecruit(0, 0, 4, false, true, true, false));
    Check(!AssistMath::CanRecruit(0, 0, 4, true, true, true, true));
    Check(!AssistMath::CanRecruit(-1, 0, 4, true, true, true, false));
}
void bench_assist_admission_100000_queries() {
    for (int index = 0; index < 100000; ++index)
        Check(AssistMath::CanRecruit(1, 0, AssistMath::TargetCount(100, 40, 20, 10), true, false, true, false));
}
