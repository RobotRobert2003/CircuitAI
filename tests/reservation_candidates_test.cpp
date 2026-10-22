#include "terrain/ReservationCandidates.h"
#include <cassert>
#include <cstdio>
int main() {
    std::set<int> slots; for(int i=1;i<=25;++i) slots.insert(i);
    int cursor=-1, calls=0;
    const auto late=[&](int id) { ++calls; return id==21; };
    assert(circuit::reservation_candidates::Next(slots,cursor,8,late)==-2 && calls==8);
    assert(circuit::reservation_candidates::Next(slots,cursor,8,late)==-2 && calls==16);
    assert(circuit::reservation_candidates::Next(slots,cursor,8,late)==21 && calls==21);
    // Rejection is builder-specific, not a global invalidation. A different
    // movement class still gets the earlier site after wrapping.
    assert(slots.count(1)==1);
    assert(circuit::reservation_candidates::Next(slots,cursor,8,[](int id){return id==1;})==1);
    slots.erase(cursor); slots.insert(0);
    assert(circuit::reservation_candidates::Next(slots,cursor,32,[](int id){return id==0;})==0);
    slots.clear();
    assert(circuit::reservation_candidates::Next(slots,cursor,8,late)==-1);
    assert(calls==21);
    std::puts("reservation candidates: bounded traversal, wrap, mutation and builder rejection PASS");
}
