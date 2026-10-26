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

int main()
{
    test_first_candidate_is_taken();
    test_lower_tier_wins_whatever_the_cost_and_distance();
    test_current_target_is_kept_inside_its_tier();
    test_dearer_then_nearer_inside_a_tier();
    std::cout << "tier_targeting_test: PASS\n";
    return 0;
}
