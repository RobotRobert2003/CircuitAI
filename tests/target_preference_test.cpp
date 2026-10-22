#include "task/fighter/TargetPreference.h"
#include <cassert>
#include <iostream>
int main()
{
    using namespace circuit::targeting;
    assert(!Preferred(0, 10000, true, true));
    assert(!Preferred(300, 20, false, false));
    assert(Preferred(300, 300, false, false));
    assert(Preferred(300, 20, true, false));
    assert(Preferred(300, 80, false, true));
    assert(WithinDetour(900*900, 20*20, 915*915));
    assert(WithinDetour(1800*1800, 900*900, 575*575));
    assert(!WithinDetour(1801*1801, 900*900, 575*575));
    assert(!WithinDetour(10000*10000, 100*100, 915*915));
    std::cout << "target preference: 9 checks passed\n";
}
