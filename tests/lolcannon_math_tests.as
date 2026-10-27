void test_rings_sit_just_inside_range() {
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 0) == 5850.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 4) == 5350.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 5) < 0.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, -1) < 0.0f);
    Check(LolCannonMath::RingRadius(0, 150, 650, 125, 0) < 0.0f);
}
void test_one_gate_per_cannon() {
    array<float> gates = {600.0f, 1000.0f};
    Check(!LolCannonMath::GateOpen(0, 599, 5000, gates, 5000, 0));
    Check(!LolCannonMath::GateOpen(0, 600, 4999, gates, 5000, 0));
    Check(LolCannonMath::GateOpen(0, 600, 5000, gates, 5000, 0));
    Check(!LolCannonMath::GateOpen(1, 999, 9000, gates, 5000, 0));
    Check(LolCannonMath::GateOpen(1, 1000, 5000, gates, 5000, 0));
    Check(!LolCannonMath::GateOpen(2, 5000, 50000, gates, 5000, 0));
}
void test_extra_cannon_every_step_past_the_last_gate() {
    array<float> gates = {600.0f, 1000.0f};
    Check(LolCannonMath::GateFor(0, gates, 50) == 600.0f);
    Check(LolCannonMath::GateFor(1, gates, 50) == 1000.0f);
    Check(LolCannonMath::GateFor(2, gates, 50) == 1050.0f);
    Check(LolCannonMath::GateFor(5, gates, 50) == 1200.0f);
    Check(LolCannonMath::GateFor(2, gates, 0) < 0.0f);
    Check(LolCannonMath::GateFor(-1, gates, 50) < 0.0f);
    Check(!LolCannonMath::GateOpen(2, 1049, 5000, gates, 5000, 50));
    Check(LolCannonMath::GateOpen(2, 1050, 5000, gates, 5000, 50));
    Check(!LolCannonMath::GateOpen(3, 1050, 5000, gates, 5000, 50));
}
void test_back_off_moves_the_rings_out() {
    Check(LolCannonMath::BackShift(0, 500) == 0.0f);
    Check(LolCannonMath::BackShift(2, 500) == 1000.0f);
    const float b = LolCannonMath::BackShift(1, 500);
    Check(LolCannonMath::RingRadius(6000, 150 - b, 650 - b, 125, 0) == 6350.0f);
    Check(LolCannonMath::RingRadius(6000, 150 - b, 650 - b, 125, 4) == 5850.0f);
    Check(LolCannonMath::RingRadius(6000, 150 - b, 650 - b, 125, 5) < 0.0f);
    Check(LolCannonMath::BackLevel(2, 3, 6) == 0);
    Check(LolCannonMath::BackLevel(3, 3, 6) == 1);
    Check(LolCannonMath::BackLevel(7, 3, 6) == 2);
    Check(LolCannonMath::BackLevel(99, 3, 6) == 6);
    Check(LolCannonMath::BackLevel(5, 0, 6) == 0);
}
void test_facing_points_at_the_direction() {
    Check(LolCannonMath::Facing(0, 10) == 0);
    Check(LolCannonMath::Facing(10, 1) == 1);
    Check(LolCannonMath::Facing(1, -10) == 2);
    Check(LolCannonMath::Facing(-10, 3) == 3);
}
void test_grid_geometry() {
    Check(LolCannonMath::Pitch(3) == 48.0f);
    Check(LolCannonMath::Pitch(4) == 64.0f);
    Check(LolCannonMath::Pitch(0) == 16.0f);
    Check(LolCannonMath::Offset(0, 4, 32) == -48.0f);
    Check(LolCannonMath::Offset(3, 4, 32) == 48.0f);
    Check(LolCannonMath::Offset(0, 1, 32) == 0.0f);
    Check(LolCannonMath::Rows(6, 2) == 3);
    Check(LolCannonMath::Rows(8, 2) == 4);
    Check(LolCannonMath::Rows(7, 2) == 4);
    Check(LolCannonMath::Rows(0, 2) == 0);
}
void test_crew_fill_order() {
    Check(LolCannonMath::CrewFor(true, 0, 0, 5, 0, 50) == 0);
    Check(LolCannonMath::CrewFor(true, 1, 0, 5, 0, 50) == 2);
    Check(LolCannonMath::CrewFor(true, 1, 5, 5, 0, 50) == 1);
    Check(LolCannonMath::CrewFor(false, 0, 0, 5, 0, 50) == 1);
    Check(LolCannonMath::CrewFor(false, 0, 0, 5, 50, 50) == -1);
    Check(LolCannonMath::CrewFor(true, 1, 5, 5, 50, 50) == -1);
}
void test_centre_out_rows() {
    array<int> six = {2, 3, 1, 4, 0, 5};
    for (int i = 0; i < 6; ++i) Check(LolCannonMath::CentreOut(i, 6) == six[i]);
    array<int> five = {2, 3, 1, 4, 0};
    for (int i = 0; i < 5; ++i) Check(LolCannonMath::CentreOut(i, 5) == five[i]);
    Check(LolCannonMath::CentreOut(0, 1) == 0);
    Check(LolCannonMath::CentreOut(1, 1) == -1);
    Check(LolCannonMath::CentreOut(0, 0) == -1);
}
