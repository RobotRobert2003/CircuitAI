#include "terrain/GroundFormation.h"
#include "terrain/GroundCohort.h"
#include <cassert>
#include <cstdio>
int main() {
    using namespace circuit;
    {
        std::vector<ranged::Point> path={{0,0},{1,0},{2,0},{3,0},{3,1},{3,2},{3,1},{4,1}};
        ranged::CompactStraightRoute(path);
        assert(path.size()==5);
        assert(path[0].x==0 && path[1].x==3 && path[1].z==0);
        assert(path[2].z==2 && path[3].z==1 && path.back().x==4);
        std::vector<ranged::Point> empty;
        ranged::CompactStraightRoute(empty); assert(empty.empty());
        std::vector<ranged::Point> diagonal={{0,0},{1,1},{2,2},{3,3}};
        ranged::CompactStraightRoute(diagonal); assert(diagonal.size()==2);
        std::vector<ranged::Point> bend={{0,0},{1,1},{2,2.01f}};
        ranged::CompactStraightRoute(bend); assert(bend.size()==3);
    }
    assert(cohort::KeepMove({0,0},{400,0},{420,20},.2f,64));
    assert(cohort::KeepMove({0,0},{400,0},{370,0},.2f,64));
    assert(!cohort::KeepMove({0,0},{400,0},{0,400},.2f,64));
    assert(!cohort::KeepMove({0,0},{400,0},{-400,0},.2f,64));
    assert(!cohort::KeepMove({0,0},{400,0},{200,0},.2f,64));
    assert(!cohort::KeepMove({0,0},{20,0},{400,0},.2f,64));
    assert(!cohort::KeepMove({0,0},{400,0},{420,20},0,64));
    const cohort::Force six{6600,360,840}, three{3600,180,810}, mass{18000,1800,3000};
    assert(cohort::Assess(six,three,12,1,1.4,1.1,.4,false).commit);
    assert(!cohort::Assess(six,mass,12,1,1.4,1.1,.4,false).commit);
    const auto one=cohort::Assess(six,three,12,1,1.4,1.1,.7,true,1);
    const auto focused=cohort::Assess(six,three,12,1,1.4,1.1,.7,true,3);
    assert(focused.loss<one.loss);
    assert(!cohort::Assess(six,mass,12,1,1.4,1.1,.7,true,10).commit);
    assert(!cohort::Assess(six,three,12,12,1.4,1.1,.4,false).commit);
    assert(!cohort::Assess({0,360,840},three,12,0,1.4,1.1,.4,false).commit);
    assert(!cohort::Assess({6600,0,840},three,12,0,1.4,1.1,.4,false).commit);
    assert(cohort::Assess(six,{500,70,100},12,2,1.4,1.1,.12,false).commit);
    assert(!cohort::Assess(six,{500,700,100},12,2,1.4,1.1,.12,false).commit);
    assert(cohort::Assess({13200,720,1680,1100},{600,100,85},12,3,1.4,1.1,.12,false).commit);
    assert(!cohort::Assess({13200,720,1680,500},{600,300,85},12,3,1.4,1.1,.12,false).commit);
    assert(cohort::ReadyWeight(380,380,45,12)==1);
    assert(cohort::ReadyWeight(920,380,45,12)==0);
    assert(cohort::RelativeClosing({0,0},{-45,0},{400,0},{-45,0})==0);
    assert(cohort::RelativeClosing({0,0},{0,0},{400,0},{-45,0})==45);
    assert(cohort::KiteStep(8,16,false)==32);
    assert(cohort::KiteStep(8,16,true)==192);
    assert(!cohort::ShortKite(380,325,45,1.25)); // narrow Centurion firing band
    assert(cohort::ShortKite(380,180,45,1.25)); // shorter-range light raiders
    assert(cohort::Admit({400,0},{0,0},450));
    assert(!cohort::Admit({800,0},{0,0},450)); // no recruitment through a chain
    assert(!cohort::CanRush(380,325,45,45,840,810,1.75,6,440)); // kite Centurion
    assert(!cohort::CanRush(380,475,45,45,1400,560,1.75,6,440)); // cannot catch
    assert(!cohort::CanRush(380,700,45,33,1400,500,1.75,6,700)); // long exposure
    assert(cohort::CanRush(380,440,45,30,1400,500,1.75,6,440));
    assert(!cohort::CanRush(380,440,45,30,700,500,1.75,6,440)); // insufficient local force
    assert(!cohort::CanRush(380,440,45,30,1400,0,1.75,6,440));
    assert(cohort::HealthValue(140,550,1100)==70);
    assert(cohort::HealthValue(140,2000,1100)==140);
    assert(cohort::HealthValue(140,-10,1100)==0);
    assert(cohort::PairSpacing(256,256,false,false,60)==256);
    assert(cohort::PairSpacing(64,64,true,true,40)==64);
    assert(cohort::PairSpacing(256,64,false,true,50)==64);
    assert(cohort::PairSpacing(64,256,true,false,50)==64);
    assert(cohort::PairSpacing(256,64,false,true,130)==130);
    for(int count=1;count<=12;++count) {
        ranged::Point prior{};
        for(int rank=0;rank<count;++rank) {
            const auto p=cohort::Arc({100,100},{0,-1},368,rank,count,64);
            assert(std::abs(ranged::DistanceSq(p,{100,100})-368*368)<.1f);
            assert(p.z<100); // never wrap behind enemy
            if(rank) assert(ranged::DistanceSq(p,prior)>=64*64);
            prior=p;
        }
    }
    assert(formation::Separation(368.6f,451.25f,64,96)>82.f);
    assert(formation::Separation(380,700,64,96)==96);
    assert(formation::Separation(380,380,64,96)==64);
    assert(formation::RearRadius(600,380,475,64,96)==695);
    assert(formation::Compatible(true,true,true,1000.f*1000.f,900,true));
    assert(!formation::Compatible(true,true,true,1000.f*1000.f,900,false));
    assert(!formation::Compatible(false,true,true,0,900,true));
    assert(!formation::Compatible(true,false,true,0,900,true));
    assert(!formation::Compatible(true,true,false,0,900,true));
    assert(cohort::CompletedStage({0,0},{63,0},{100,0},64));
    assert(!cohort::CompletedStage({0,0},{64,0},{100,0},64));
    assert(!cohort::CompletedStage({0,0},{32,0},{160,0},64));
    assert(cohort::CompletedStage({0,0},{32,0},{159,0},64));
    std::puts("ground cohort: catchability, strength, health and 78 firing slots PASS");
}
