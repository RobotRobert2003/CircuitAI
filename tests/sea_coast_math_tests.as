void test_opening_is_never_a_defeat() {
    Check(!SeaCoastMath::Lost(false,false,100000,900));
}
void test_shipyard_loss_with_surviving_navy_is_not_defeat() {
    Check(!SeaCoastMath::Lost(true,true,100000,900));
}
void test_loss_requires_continuous_absence() {
    Check(!SeaCoastMath::Lost(true,false,899,900));
    Check(SeaCoastMath::Lost(true,false,900,900));
}
void test_retake_has_its_own_hysteresis() {
    Check(!SeaCoastMath::Retaken(true,1799,1800));
    Check(SeaCoastMath::Retaken(true,1800,1800));
    Check(!SeaCoastMath::Retaken(false,99999,1800));
}
void test_beach_ownership_is_nearest_and_ties_are_deterministic() {
    Check(SeaCoastMath::OwnBeach(4,9,7,2));
    Check(!SeaCoastMath::OwnBeach(9,4,2,7));
    Check(SeaCoastMath::OwnBeach(4,4,2,7));
    Check(!SeaCoastMath::OwnBeach(4,4,7,2));
}
void test_tech_requires_both_resources_or_whole_purchase_banked() {
    Check(SeaCoastMath::TechFunded(25,600,0,0,2000,10000,25,600));
    Check(!SeaCoastMath::TechFunded(25,599,0,0,2000,10000,25,600));
    Check(!SeaCoastMath::TechFunded(24,600,0,0,2000,10000,25,600));
    Check(SeaCoastMath::TechFunded(0,0,2000,10000,2000,10000,25,600));
}
