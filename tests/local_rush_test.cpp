#include "terrain/LocalRush.h"
#include <cassert>
#include <iostream>
using namespace circuit;
int main() {
    assert(rush::Score(2000,1000,2,0)==0);
    assert(rush::Score(1800,1000,2,.5f)>0);
    assert(rush::Score(2500,1000,2,-1)<0);
    assert(!rush::Exhausted(2,8,.25f)); // exactly 25% still committed
    assert(rush::Exhausted(1,8,.25f));
    rush::Registry r;
    std::vector<rush::Registry::Member> members;
    for(int i=0;i<8;++i) members.push_back({i,true});
    members.push_back({8,false});
    const int first=r.Start(members,.25f,600);
    for(int i=0;i<6;++i) r.Leave(i);
    assert(r.Active(6) && r.Get(first)->initial==8 && r.Get(first)->remaining==2);
    r.Reinforce(first,{{30,true},{31,false}});
    assert(r.Valid() && r.Get(first)->initial==8 && r.Get(first)->remaining==2 && r.Active(30));
    // A reused/reinforcement identity cannot join or inflate the old baseline.
    const int second=r.Start({{0,true},{6,true},{20,true}},.25f,300);
    assert(r.Get(second)->initial==2 && r.Get(first)->initial==8);
    r.Leave(6);
    assert(!r.Active(7) && !r.Active(8) && r.Active(0));
    r.Finish(first,1200);
    assert(r.Find(7)<0 && r.Cooldown(7)==1800 && r.Cooldown(8)==1800);
    r.Leave(8); assert(r.Cooldown(8)==0);
    r.Leave(0); r.Leave(20); assert(!r.Get(second));
    assert(r.Valid());
    std::cout << "local rush score, exact loss boundary, fixed roster, ID reuse, independent campaigns and cooldown: PASS\n";
}
