void test_cell_key_merges_nearby_deaths() {
    Check(IdleReclaimMath::CellKey(100, 100, 384) == IdleReclaimMath::CellKey(300, 380, 384));
    Check(IdleReclaimMath::CellKey(100, 100, 384) != IdleReclaimMath::CellKey(400, 100, 384));
    Check(IdleReclaimMath::CellKey(100, 100, 384) != IdleReclaimMath::CellKey(100, 400, 384));
    Check(IdleReclaimMath::CellKey(5, 5, 0) == IdleReclaimMath::CellKey(5, 5, 1));
}
void test_wreck_metal_is_a_share_of_cost() {
    const float m = IdleReclaimMath::WreckMetal(100, 0.6f);
    Check(m > 59.999f && m < 60.001f);
    Check(IdleReclaimMath::WreckMetal(0, 0.6f) == 0.0f);
    Check(IdleReclaimMath::WreckMetal(100, 0) == 0.0f);
}
void test_rich_far_site_can_beat_poor_near_site() {
    Check(IdleReclaimMath::Score(1000, 2000, 600) > IdleReclaimMath::Score(100, 200, 600));
    Check(IdleReclaimMath::Score(100, 200, 600) > IdleReclaimMath::Score(100, 2000, 600));
    Check(IdleReclaimMath::Score(0, 10, 600) == 0.0f);
}
void test_site_expires_after_lifetime() {
    Check(!IdleReclaimMath::Expired(100, 0, 101));
    Check(IdleReclaimMath::Expired(101, 0, 101));
    Check(!IdleReclaimMath::Expired(999999, 0, 0));
}
void test_idle_work() {
    Check(IdleReclaimMath::IdleWork(false, false, false, false, false));
    Check(IdleReclaimMath::IdleWork(true, true, false, false, false));
    Check(IdleReclaimMath::IdleWork(true, false, true, false, false));
    Check(IdleReclaimMath::IdleWork(true, false, false, true, false));   // assisting a factory
    Check(!IdleReclaimMath::IdleWork(true, false, false, true, true));   // assisting a constructor
    Check(!IdleReclaimMath::IdleWork(true, false, false, false, false)); // building
}
void test_all_safe() {
    array<float> calm = {0, 0.2f, 0.5f};
    array<float> hot = {0, 0.6f, 0};
    Check(IdleReclaimMath::AllSafe(calm, 0.5f));
    Check(!IdleReclaimMath::AllSafe(hot, 0.5f));
}
