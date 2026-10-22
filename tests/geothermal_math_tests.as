void test_geo_requires_both_resources() {
    Check(!GeothermalMath::Affordable(540,13000,100,500,10,100,90,0.5f));
    Check(GeothermalMath::Affordable(540,13000,100,500,10,300,90,0.5f));
    Check(!GeothermalMath::Affordable(1500,27000,0,30000,10,1000,90,0.5f));
}
void test_geo_no_speculative_refund() {
    Check(!GeothermalMath::Affordable(1500,27000,1499,27000,0,0,90,0.5f));
    Check(GeothermalMath::Affordable(1500,27000,1500,27000,0,0,90,0.5f));
}
void test_geo_budget_validation() {
    Check(!GeothermalMath::Affordable(1,1,100,100,1,1,0,0.5f));
    Check(!GeothermalMath::Affordable(1,1,100,100,1,1,90,1.5f));
}
