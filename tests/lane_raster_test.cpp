#include "terrain/LaneRaster.h"
#include <cassert>
#include <cstdio>
using namespace circuit::lane;
int main() {
    const std::vector<Point> sparse={{32,0,32},{4000,0,32},{4000,0,2016}};
    std::vector<Point> dense;
    for(int x=32;x<=4000;x+=64)dense.emplace_back(float(x),0,32);
    for(int z=96;z<=2016;z+=64)dense.emplace_back(4000,0,float(z));
    const auto a=CorridorDistances(sparse,64,40,64),b=CorridorDistances(dense,64,40,64);
    assert(a==b); assert(a[31]==0); assert(a[20*64+62]==0);
    assert(a[10*64+31]==640);
    auto reverse=sparse;std::reverse(reverse.begin(),reverse.end());
    assert(CorridorDistances(reverse,64,40,64)==a);
    assert(CorridorDistances({},64,40,64).empty());
    const auto diagonal=CorridorDistances({{32,0,32},{2016,0,2016}},64,40,64);
    assert(diagonal[15*64+15]==0);
    std::puts("lane_raster_test: PASS sparse/dense, bends, reverse, empty, diagonal");
}
