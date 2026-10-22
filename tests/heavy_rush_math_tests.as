void test_heavy_mammoth_sustained_budget() {
    Check(HeavyRushMath::CanFund(2200,35000,40,600,0,0,90,0.70f,40));
}
void test_heavy_conversion_is_interruptible() {
    Check(HeavyRushMath::AvailableEnergy(1000,900,800,200) == 700);
    Check(HeavyRushMath::AvailableEnergy(1000,900,0,200) == 0);
    Check(HeavyRushMath::AvailableEnergy(1000,100,800,200) == 800);
}
void test_heavy_donated_bank_bypasses_income_floor() {
    Check(HeavyRushMath::CanFund(2200,35000,10,600,2200,0,90,0.70f,40));
}
void test_heavy_no_money_cannot_start() {
    Check(!HeavyRushMath::CanFund(2200,35000,10,600,2199,0,90,0.70f,40));
}
void test_heavy_energy_stall_blocks_even_full_metal() {
    Check(!HeavyRushMath::CanFund(2200,35000,100,0,10000,100000,90,0.70f,40));
}
void test_heavy_essential_energy_is_not_available_budget() {
    Check(!HeavyRushMath::CanFund(2200,35000,100,100,10000,0,90,0.70f,40));
}
void test_heavy_invalid_budget_fails_closed() {
    Check(!HeavyRushMath::CanFund(2200,35000,100,1000,10000,10000,0,0.70f,40));
    Check(!HeavyRushMath::CanFund(2200,35000,100,1000,10000,10000,90,1.01f,40));
}
void test_heavy_first_fusion_prerequisite_is_scoped_to_pending_rush() {
    Check(HeavyRushMath::RequiresFusion(true, 0, 0, 1000));
    Check(HeavyRushMath::RequiresFusion(true, 0, 999, 1000));
    Check(!HeavyRushMath::RequiresFusion(true, 0, 1000, 1000));
    Check(!HeavyRushMath::RequiresFusion(true, 1, 0, 1000));
    Check(!HeavyRushMath::RequiresFusion(false, 0, 0, 1000));
}
