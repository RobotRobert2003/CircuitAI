#include "terrain/WaterSurvey.h"
#include <cassert>
#include <iostream>
int main() {
    using namespace circuit::survey;
    assert(Observe(-1,100,true,false)==-1);
    assert(Observe(-1,100,false,true)==-1);
    assert(Observe(-1,100,true,true)==100);
    assert(Observe(100,150,false,false)==100);
    assert(!Fresh(-1,100,600));
    assert(Fresh(100,700,600));
    assert(!Fresh(100,701,600));
    assert(!Fresh(100,99,600));
    assert(!Fresh(100,100,-1));
    std::cout << "water survey: 9 checks passed\n";
}
