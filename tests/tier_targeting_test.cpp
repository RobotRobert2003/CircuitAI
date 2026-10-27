#include "task/static/TierTargeting.h"
#include <cassert>
#include <iostream>
using namespace circuit::tier;

void test_first_candidate_is_taken()
{
    const Candidate c{1, 6, 50.f, 100.f};
    assert(Better(c, nullptr, -1));
}
void test_lower_tier_wins_whatever_the_cost_and_distance()
{
    const Candidate afus{1, 1, 9000.f, 9.e6f};
    const Candidate llt{2, 6, 90.f, 1.f};
    assert(Better(afus, &llt, -1));
    assert(!Better(llt, &afus, -1));
    // even when the cheaper tier is the one under fire
    assert(Better(afus, &llt, 2));
}
void test_current_target_is_kept_inside_its_tier()
{
    const Candidate fus{10, 4, 4000.f, 100.f};
    const Candidate com{11, 4, 1200.f, 900.f};
    assert(!Better(fus, &com, 11));
    assert(Better(com, &fus, 11));
}
void test_dearer_then_nearer_inside_a_tier()
{
    const Candidate dear{1, 3, 2000.f, 900.f};
    const Candidate cheap{2, 3, 1000.f, 100.f};
    assert(Better(dear, &cheap, -1));
    assert(!Better(cheap, &dear, -1));
    const Candidate near{3, 3, 1000.f, 50.f};
    assert(Better(near, &cheap, -1));
    assert(!Better(cheap, &near, -1));
}

std::vector<Area> six_areas()
{
    std::vector<Ranked> r;
    // six afus 2000 apart (tier 1, falling cost), plus a fusion beside the first
    for (int i = 0; i < 6; ++i) r.push_back({{100 + i, 1, 9000.f - 100.f * i, 1.e6f}, 1000.f + 2000.f * i, 500.f});
    r.push_back({{200, 4, 4000.f, 1.e6f}, 1100.f, 600.f});
    return BuildAreas(r, 600.f, 6);
}
void test_areas_group_round_the_best_target()
{
    const std::vector<Area> a = six_areas();
    assert(a.size() == 6);
    assert(a[0].bestId == 100 && a[0].members == 2);   // the fusion joined the first afus
    assert(a[5].bestId == 105);
    std::vector<Ranked> r;
    for (int i = 0; i < 9; ++i) r.push_back({{i, 2, 100.f, 1.f}, 5000.f * i, 0.f});
    assert(BuildAreas(r, 600.f, 3).size() == 3);           // capped
}
void test_rotation_by_time_visits_each_area_then_starts_over()
{
    const std::vector<Area> a = six_areas();
    Rotation rot;
    bool restarted, moved;
    assert(rot.Pick(a, 0, 600, 0, restarted, moved) == 0 && restarted);
    assert(rot.Pick(a, 599, 600, 0, restarted, moved) == 0 && !moved);
    for (int k = 1; k < 6; ++k) assert(rot.Pick(a, 600 * k, 600, 0, restarted, moved) == k && moved);
    assert(rot.Pick(a, 3600, 600, 0, restarted, moved) == 0 && moved && !restarted);   // back to the top
}
void test_rotation_by_shots_two_each()
{
    std::vector<Area> a = six_areas();
    a.resize(3);
    Rotation rot;
    bool restarted, moved;
    assert(rot.Pick(a, 0, 0, 2, restarted, moved) == 0);
    rot.OnShot();
    assert(rot.Pick(a, 10, 0, 2, restarted, moved) == 0);
    rot.OnShot();
    assert(rot.Pick(a, 20, 0, 2, restarted, moved) == 1);
    rot.OnShot(); rot.OnShot();
    assert(rot.Pick(a, 30, 0, 2, restarted, moved) == 2);
    rot.OnShot(); rot.OnShot();
    assert(rot.Pick(a, 40, 0, 2, restarted, moved) == 0);
}
void test_rotation_restarts_when_the_top_target_changes()
{
    std::vector<Area> a = six_areas();
    Rotation rot;
    bool restarted, moved;
    rot.Pick(a, 0, 600, 0, restarted, moved);
    rot.Pick(a, 600, 600, 0, restarted, moved);
    assert(rot.Pick(a, 1200, 600, 0, restarted, moved) == 2);
    a.erase(a.begin());                       // the top was scouted dead
    assert(rot.Pick(a, 1300, 600, 0, restarted, moved) == 0 && restarted);
    assert(rot.Pick(a, 1300, 600, 0, restarted, moved) == 0 && !restarted);
    assert(rot.Pick(std::vector<Area>(), 1400, 600, 0, restarted, moved) == -1);
}

int main()
{
    test_first_candidate_is_taken();
    test_lower_tier_wins_whatever_the_cost_and_distance();
    test_current_target_is_kept_inside_its_tier();
    test_dearer_then_nearer_inside_a_tier();
    test_areas_group_round_the_best_target();
    test_rotation_by_time_visits_each_area_then_starts_over();
    test_rotation_by_shots_two_each();
    test_rotation_restarts_when_the_top_target_changes();
    std::cout << "tier_targeting_test: PASS\n";
    return 0;
}
