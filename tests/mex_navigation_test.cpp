#include "resource/MexNavigation.h"
#include <cassert>
#include <iostream>

using namespace circuit::mex_navigation;
int main() {
    assert(Protected(17999,18000)); assert(!Protected(18000,18000));
    assert(!Protected(0,0)); assert(Protected(899,900)); assert(!Protected(900,900));
    assert(InBuildRange(80,60,0,100));
    assert(!InBuildRange(80,300,0,300));
    assert(!InBuildRange(80,-300,0,300));
    assert(!InBuildRange(0,Unreachable,0,300));
    assert(Better(100,2,100,3)); assert(!Better(100,3,100,2));
    assert(!Better(Unreachable,0,Unreachable,-1));
    const int w=9,h=9,goal=2*w+5;
    auto pass=[](int i) { return i%w!=4 || i/w==8; };
    auto cost=[](int a,int b) { return std::hypot(float(a%w-b%w),float(a/w-b/w)); };
    const auto left=Distances(w,h,2*w+3,0,pass,cost);
    const auto right=Distances(w,h,6*w+6,0,pass,cost);
    assert(left[goal]>right[goal]); assert(left[goal]>12);
    const auto hill=Distances(3,3,0,0,[](int i){return i==0 || i==4 || i==8;},[](int,int){return 1.f;});
    assert(!std::isfinite(hill[8]));
    const auto absent=Distances(3,3,-1,0,[](int){return true;},[](int,int){return 1.f;});
    assert(!std::isfinite(absent[0]));
    std::cout << "mex_navigation_test: PASS time boundary, 3D range, detour, tie, disconnected terrain\n";
}
