#include "task/static/TierTargeting.h"
#include <cassert>
#include <iostream>
#include <vector>
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

Candidate At(int id, int tier, float cost, float x, float z)
{
    return Candidate{id, tier, cost, x * x + z * z, x, z};
}
void test_areas_rank_by_best_tier_then_metal()
{
    // an advanced fusion alone; three fusions together; one fusion alone
    const std::vector<Candidate> cs{
        At(1, 1, 9000.f, 0.f, 0.f),
        At(2, 4, 4000.f, 2000.f, 0.f), At(3, 4, 4000.f, 2100.f, 0.f), At(4, 4, 4000.f, 2000.f, 150.f),
        At(5, 4, 4500.f, 0.f, 3000.f),
    };
    const auto areas = BuildAreas(cs, 300.f, -1, 6);
    assert(areas.size() == 3);
    assert(areas[0].seedId == 1 && areas[0].tier == 1);
    // the cluster outranks the single dearer fusion: 12000 metal against 4500
    assert(areas[1].tier == 4 && areas[1].metal == 12000.f);
    assert(areas[2].seedId == 5);
}
void test_area_aims_at_its_best_target_and_keeps_the_one_under_fire()
{
    const std::vector<Candidate> cs{
        At(1, 6, 50.f, 0.f, 0.f), At(2, 4, 4000.f, 100.f, 0.f), At(3, 4, 3000.f, 0.f, 100.f),
    };
    auto areas = BuildAreas(cs, 300.f, -1, 6);
    assert(areas.size() == 1 && cs[areas[0].aim].id == 2 && areas[0].metal == 7050.f);
    areas = BuildAreas(cs, 300.f, 3, 6);
    assert(cs[areas[0].aim].id == 3);
}
void test_area_count_is_capped()
{
    std::vector<Candidate> cs;
    for (int i = 0; i < 10; ++i) cs.push_back(At(i, 6, 50.f + i, 1000.f * i, 0.f));
    const auto areas = BuildAreas(cs, 300.f, -1, 3);
    assert(areas.size() == 3);
    assert(areas[0].seedId == 9 && areas[1].seedId == 8 && areas[2].seedId == 7);
}
void test_rotation_dwells_by_time_and_wraps()
{
    Rotation r;
    Restart(r, 0);
    assert(!Advance(r, 6, 599, 600, 0) && r.index == 0);
    for (int k = 1; k < 6; ++k) assert(Advance(r, 6, 600 * k, 600, 0) && r.index == k);
    assert(Advance(r, 6, 3600, 600, 0) && r.index == 0);
    // fewer areas than the rotation: wraps at what there is
    r.index = 4;
    assert(Advance(r, 3, 4000, 600, 0) && r.index == 0);
}
void test_rotation_dwells_by_shots()
{
    Rotation r;
    Restart(r, 0);
    r.shots = 1;
    assert(!Advance(r, 3, 9000, 600, 2));
    r.shots = 2;
    assert(Advance(r, 3, 9000, 600, 2) && r.index == 1 && r.shots == 0);
    // one area only: it stays on it
    Rotation one;
    one.shots = 2;
    assert(!Advance(one, 1, 10, 600, 2) && one.index == 0 && one.shots == 0);
}
void test_top_change_needs_fresh_news()
{
    assert(TopChanged(-1, 5, false, false));  // first scan
    assert(!TopChanged(5, 5, true, true));
    assert(TopChanged(5, 7, false, true));    // the old top is gone
    assert(TopChanged(5, 7, true, false));    // a newly scouted target tops it
    assert(!TopChanged(5, 7, true, true));    // a reshuffle among known targets
}

int main()
{
    test_first_candidate_is_taken();
    test_lower_tier_wins_whatever_the_cost_and_distance();
    test_current_target_is_kept_inside_its_tier();
    test_dearer_then_nearer_inside_a_tier();
    test_areas_rank_by_best_tier_then_metal();
    test_area_aims_at_its_best_target_and_keeps_the_one_under_fire();
    test_area_count_is_capped();
    test_rotation_dwells_by_time_and_wraps();
    test_rotation_dwells_by_shots();
    test_top_change_needs_fresh_news();
    std::cout << "tier_targeting_test: PASS\n";
    return 0;
}
