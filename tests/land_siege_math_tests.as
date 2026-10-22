void test_no_static_no_army_or_low_income_has_no_siege_budget() {
    Check(LandSiegeMath::Budget(39,40,120,10000,10000,1.25f,.2f,.35f,1)==0);
    Check(LandSiegeMath::Budget(120,40,120,0,10000,1.25f,.2f,.35f,1)==0);
    Check(LandSiegeMath::Budget(120,40,120,10000,0,1.25f,.2f,.35f,1)==0);
}
void test_income_ramp_preserves_a_screen_and_is_bounded() {
    Check(LandSiegeMath::Budget(40,40,120,10000,10000,1.25f,.2f,.35f,1)==2000);
    Check(LandSiegeMath::Budget(80,40,120,10000,10000,1.25f,.2f,.35f,1)==2750);
    Check(LandSiegeMath::Budget(120,40,120,10000,10000,1.25f,.2f,.35f,1)==3500);
    Check(LandSiegeMath::Budget(10000,40,120,10000,10000,1.25f,.2f,.35f,1)==3500);
}
void test_response_stops_when_threat_or_projected_shortage_is_gone() {
    Check(LandSiegeMath::Budget(120,40,120,800,10000,1.25f,.2f,.35f,1)==1000);
    Check(LandSiegeMath::Budget(120,40,120,800,10000,1.25f,.2f,.35f,2)==500);
    Check(LandSiegeMath::CanAdd(4000,2150,1850));
    Check(!LandSiegeMath::CanAdd(4000,2151,1850));
    Check(!LandSiegeMath::CanAdd(1800,0,1850));
    Check(!LandSiegeMath::CanAdd(10000,0,0));
}
