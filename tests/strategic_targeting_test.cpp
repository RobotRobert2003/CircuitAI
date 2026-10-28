#include "task/static/StrategicTargeting.h"
#include <cassert>
#include <iostream>
using namespace circuit::strategic;

void test_sensors_towers_outrank_mobile_and_radar()
{
    assert(SensorClass(true, false, false, true) == 0);
    assert(SensorClass(true, false, false, false) == 1);
    assert(SensorClass(false, true, false, true) == 2);
    assert(SensorClass(false, true, false, false) == 3);
    assert(SensorClass(true, true, true, true) == 4);
    assert(SensorClass(false, true, true, false) == 5);
    assert(SensorClass(false, false, false, true) == -1);
}
void test_nuclear_mobile_including_t3_is_rejected()
{
    assert(!NuclearTarget(true, true, true));
    assert(!NuclearTarget(false, false, true));
    assert(NuclearTarget(false, true, true));
    assert(NuclearTarget(true, true, false)); // explicit policy lever
}
void test_silo_history_is_local_and_expires_at_five_minutes()
{
    Ledger history;
    history.Add(10, {3000,3000}, 1000, 600, 9000, false);
    assert(history.Blocked({3000,3000}, 10, 9599, true));
    assert(history.Blocked({3999,3000}, 10, 9599, true));
    assert(!history.Blocked({4001,3000}, 10, 9599, true));
    assert(!history.Blocked({3000,3000}, 11, 601, true));
    assert(!history.Blocked({3000,3000}, 10, 9600, true));
}
void test_allied_pulse_pending_claim_is_exclusive_and_cancellable()
{
    Ledger claims;
    claims.Add(10, {3000,3000}, 1400, 0, 1350, true);
    assert(claims.Blocked({4000,3000}, 11, 1, false));
    assert(!claims.Blocked({3000,3000}, 10, 1, false));
    assert(!claims.Blocked({3000,3000}, 11, 1350, false));
    claims.ReleasePending(10);
    assert(!claims.Blocked({3000,3000}, 11, 1, false));
}
void test_pulse_launch_blocks_owner_and_allies_but_keeps_other_areas_available()
{
    Ledger claims;
    claims.Add(10, {3000,3000}, 1400, 0, 1350, true);
    claims.Add(10, {3000,3000}, 1400, 60, 2700, false);
    claims.ReleasePending(10); // task recreation cannot erase a launched pulse
    assert(claims.Blocked({3000,3000}, 10, 61, false));
    assert(claims.Blocked({3000,3000}, 11, 61, false));
    assert(!claims.Blocked({5000,3000}, 11, 61, false));
    assert(!claims.Blocked({3000,3000}, 11, 2760, false));
}
void test_old_shots_survive_new_target_and_dead_unit_history_is_pruned()
{
    Ledger history;
    history.Add(10, {3000,3000}, 1000, 0, 9000, false);
    history.Add(10, {6000,6000}, 1000, 60, 9000, false);
    assert(history.Blocked({3000,3000}, 10, 61, true));
    assert(history.Blocked({6000,6000}, 10, 61, true));
    history.Prune(61, [](int) { return false; });
    assert(!history.Blocked({3000,3000}, 10, 62, true));
}
void test_overnuke_counts_scouts_every_ten_and_blocks_the_finished_target()
{
    Overnuke over;
    assert(!over.Active() && !over.Covers({3000,3000}));
    over.Begin({3000,3000}, 1000, 20);
    assert(over.Active() && over.Covers({3900,3000}) && !over.Covers({4100,3000}));
    assert(!over.Count({5000,3000}, 100, 9000, 10)); // elsewhere: not this target
    for (int i = 0; i < 9; ++i) assert(over.Count({3000,3000}, 100, 9000, 10));
    assert(over.Scouts() == 0);
    assert(over.Count({3000,3000}, 100, 9000, 10) && over.Scouts() == 1);
    for (int i = 0; i < 10; ++i) over.Count({3000,3000}, 200, 9000, 10);
    assert(over.Scouts() == 2 && over.Fired() == 20 && !over.Active());
    assert(over.Done({3000,3000}, 9199) && !over.Done({3000,3000}, 9200));
    over.Begin({8000,8000}, 1000, 17);
    over.Count({8000,8000}, 300, 9000, 10);
    over.End(300, 9000); // early: nothing left there
    assert(!over.Active() && over.Goal() == 1 && over.Done({8000,8000}, 400));
}
int main()
{
    test_sensors_towers_outrank_mobile_and_radar();
    test_nuclear_mobile_including_t3_is_rejected();
    test_silo_history_is_local_and_expires_at_five_minutes();
    test_allied_pulse_pending_claim_is_exclusive_and_cancellable();
    test_pulse_launch_blocks_owner_and_allies_but_keeps_other_areas_available();
    test_old_shots_survive_new_target_and_dead_unit_history_is_pruned();
    test_overnuke_counts_scouts_every_ten_and_blocks_the_finished_target();
    std::cout << "strategic targeting: seven suites passed\n";
}
