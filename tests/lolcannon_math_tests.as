void test_rings_sit_just_inside_range() {
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 0) == 5850.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 4) == 5350.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, 5) < 0.0f);
    Check(LolCannonMath::RingRadius(6000, 150, 650, 125, -1) < 0.0f);
    Check(LolCannonMath::RingRadius(0, 150, 650, 125, 0) < 0.0f);
}
void test_one_gate_per_cannon() {
    array<float> gates = {600.0f, 1000.0f};
    Check(!LolCannonMath::GateOpen(0, 599, 5000, gates, 5000));
    Check(!LolCannonMath::GateOpen(0, 600, 4999, gates, 5000));
    Check(LolCannonMath::GateOpen(0, 600, 5000, gates, 5000));
    Check(!LolCannonMath::GateOpen(1, 999, 9000, gates, 5000));
    Check(LolCannonMath::GateOpen(1, 1000, 5000, gates, 5000));
    Check(!LolCannonMath::GateOpen(2, 5000, 50000, gates, 5000));
}
void test_facing_points_at_the_direction() {
    Check(LolCannonMath::Facing(0, 10) == 0);
    Check(LolCannonMath::Facing(10, 1) == 1);
    Check(LolCannonMath::Facing(1, -10) == 2);
    Check(LolCannonMath::Facing(-10, 3) == 3);
}
void test_grid_geometry() {
    Check(LolCannonMath::Pitch(3) == 32.0f);
    Check(LolCannonMath::Pitch(4) == 32.0f);
    Check(LolCannonMath::Pitch(5) == 48.0f);
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
