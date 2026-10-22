#include "terrain/CommanderCombat.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <limits>
#include <random>
#include <string>
using namespace circuit::commander;
static Contact Enemy(int id,float x,float z,float cost=100) {
    Contact c; c.id=id; c.pos={x,z}; c.radius=12; c.cost=cost; c.health=500; c.damage=99999; return c;
}
int main(int argc,char** argv) {
    // AFUS defence: tier outranks distance/cost/retained lower-tier ownership;
    // stable equal-tier ownership, then deterministic distance/ID ties.
    assert(PreferDefenceTarget(3,9,900,2,1,100,1));
    assert(PreferDefenceTarget(2,9,900,1,1,100,1));
    assert(!PreferDefenceTarget(1,1,10,3,9,900,1));
    assert(!PreferDefenceTarget(2,9,100,2,1,900,1));
    assert(PreferDefenceTarget(2,1,900,2,9,100,1));
    assert(PreferDefenceTarget(1,2,100,1,9,101,-1));
    assert(PreferDefenceTarget(1,2,100,1,9,100,-1));
    assert(!PreferDefenceTarget(1,9,100,1,2,100,-1));
    const auto onMap=[](Point p) {
        return std::isfinite(p.x) && std::isfinite(p.z)
            && p.x>=0 && p.z>=0 && p.x<6144 && p.z<10240;
    };
    // Reported F30917 crash: both the spread site and rear fallback leave
    // Glitters. Also exercise each other edge and a legal fallback.
    assert(!LineBuildSite({409,10224},{0,-1},96,2,onMap));
    assert(!LineBuildSite({409,32},{0,1},96,2,onMap));
    assert(!LineBuildSite({32,409},{1,0},96,2,onMap));
    assert(!LineBuildSite({6128,409},{-1,0},96,2,onMap));
    auto fallback=LineBuildSite({16,100},{0,1},96,1,onMap);
    assert(fallback && fallback->x==16 && fallback->z==52);
    assert(!LineBuildSite({16,100},{0,1},96,1,[&](Point p) { return onMap(p) && p.x>=32; }));
    // Same two candidates, order and float arithmetic as the old selector;
    // the only difference is rejecting its inadmissible fallback.
    std::mt19937 lineRng(314);
    std::uniform_real_distribution<float> xSite(0,6144),zSite(0,10240),angle(-3.14f,3.14f);
    for(int trial=0;trial<20000;++trial) {
        const Point anchor{xSite(lineRng),zSite(lineRng)};
        const float a=angle(lineRng),spacing=96.f;
        const Point threat{std::cos(a),std::sin(a)},lateral{-threat.z,threat.x};
        const int count=trial%12;
        const float side=float((count+1)/2)*(count%2?1.f:-1.f);
        Point old=anchor+lateral*(side*spacing)-threat*(spacing*.5f);
        if(!onMap(old)) old=anchor-threat*(spacing*.5f);
        const auto site=LineBuildSite(anchor,threat,spacing,count,onMap);
        assert(bool(site)==onMap(old));
        if(site) assert(site->x==old.x && site->z==old.z);
    }
    std::vector<Contact> contacts={Enemy(1,80,0),Enemy(2,150,0),Enemy(3,220,0),Enemy(4,150,100,200)};
    auto line=ScoreLine(contacts,{}, {1,0},250,500,8,40,12);
    assert(line.kills==3 && line.value==420 && line.target==1);
    contacts[1].blocker=true;
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==1);
    contacts[1].blocker=false; contacts[2].friendly=true;
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).blocked);
    contacts[2].friendly=false; contacts[0].reserved=true;
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==2);
    contacts={Enemy(1,150,0)}; contacts[0].velocity={0,300};
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==0);
    contacts={Enemy(1,150,0,20000)}; contacts[0].health=335000;
    line=ScoreLine(contacts,{}, {1,0},250,500,8,40,12);
    assert(line.kills==0 && line.value>5900 && line.value<6000);
    assert(Reserve(500,2,100,1000,1,2,150)==3250);
    assert(Affordable(500,500) && !Affordable(499.99f,500));
    assert(!Affordable(std::numeric_limits<float>::quiet_NaN(),500));
    assert(MinimumValue(200,0,.25f)==200);
    assert(MinimumValue(200,1,.25f)<200 && MinimumValue(200,-1,.25f)>200);
    assert(Survivable(3700,3700,2000,.35f) && !Survivable(3700,3700,2600,.35f));
    assert(ScoreLine(contacts,{}, {},250,500,8,40,12).target==-1);
    contacts={Enemy(1,269,19)};
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==0);
    contacts[0].pos={269,0};
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==1);
    contacts={Enemy(1,100,0),Enemy(2,200,0)}; contacts[0].stopAfter=true;
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,40,12).kills==1);
    ShotClaims claims;
    claims.Reserve({0,10,1,77,30,500});
    claims.Reserve({1,11,1,77,33,600});
    assert(claims.Reserved(77,0,10)==600 && claims.Reserved(77,2,12)==1100);
    claims.Prune(31); assert(claims.Reserved(77,2,12)==600);
    claims.Release(1,11); assert(claims.Reserved(77,2,12)==0);
    assert(TravelSeconds(40,40,1,1000,0)>1);
    assert(TravelSeconds(40,40,1,1000,1)>TravelSeconds(40,40,1,1000,0));
    // Independent cross-product oracle, including rotated and negative rays.
    std::mt19937 rng(291); std::uniform_real_distribution<float> value(-300,300);
    for(int trial=0;trial<1000;++trial) {
        contacts.clear(); int expected=0;
        const Point direction=Normal({value(rng),value(rng)});
        for(int i=0;i<80;++i) {
            auto c=Enemy(i,value(rng),value(rng)); contacts.push_back(c);
            const float along=c.pos.x*direction.x+c.pos.z*direction.z;
            const float cross=std::abs(c.pos.x*direction.z-c.pos.z*direction.x);
            const float beyond=std::max(0.f,along-250.f);
            if(along>=0 && cross*cross+beyond*beyond<=400) ++expected;
        }
        assert(ScoreLine(contacts,{},direction,250,500,8,0,12).kills==expected);
    }
    // A scout crossing the approach forces decloak even with clear endpoints.
    assert(Separation({0,0},{100,0},{50,100},{0,-200},1)<.001f);
    assert(std::abs(Separation({0,0},{100,0},{50,100},{},1)-100)<.001f);
    assert(std::abs(Separation({0,0},{0,0},{50,0},{},0)-50)<.001f);
    assert(Separation({0,0},{100,0},{200,0},{100,0},1)>199);
    // Death explosions use the commander's armour damage and surface distance.
    assert(BlastDamage(2800,1280,0,1500)==0);
    assert(BlastDamage(2800,1280,1,640)==2800);
    assert(std::abs(BlastDamage(2800,1280,0,640)-1400)<.01f);
    assert(!Survivable(1900,3700,BlastDamage(2800,1280,0,300),.2f));
    assert(Survivable(3700,3700,BlastDamage(2800,1280,0,300),.2f));
    contacts={Enemy(10,100,0),Enemy(20,200,0)};
    assert(ScoreLine(contacts,{}, {1,0},250,500,8,0,12,20).requiredHit);
    contacts[0].stopAfter=true;
    assert(!ScoreLine(contacts,{}, {1,0},250,500,8,0,12,20).requiredHit);
    contacts[0].stopAfter=false; contacts[0].friendly=true;
    assert(!ScoreLine(contacts,{}, {1,0},250,500,8,0,12,20).requiredHit);
    // D-293 fallback group: seed within reach, members within the group radius.
    std::vector<Attacker> attackers={{{500,0},150},{{700,0},150},{{900,0},150}};
    auto group=StrongestGroup(attackers,{},600,400);
    assert(group.seed==0 && group.metal==450 && group.centre.x==700 && group.centre.z==0);
    assert(StrongestGroup(attackers,{},600,150).metal==150);      // members must be near the seed
    assert(StrongestGroup(attackers,{},400,400).seed==-1);        // no capable unit in reach
    assert(StrongestGroup({{{599,0},400}},{},600,400).metal==400); // exact metal threshold reaches 400
    assert(StrongestGroup({{{601,0},400}},{},600,400).seed==-1);   // just beyond reach is excluded
    attackers={{{0,300},250},{{0,-300},250},{{0,-500},250}};
    group=StrongestGroup(attackers,{},600,250);
    assert(group.seed==1 && group.metal==500);                    // larger cluster wins
    attackers={{{300,0},200},{{-300,0},200}};
    assert(StrongestGroup(attackers,{},600,100).seed==0);         // ties keep engine order
    // The shared base can relocate between 1 Hz plans, while the commander
    // continues to hold the same station. An unrelated retreat must not shift
    // its admissible sidesteps or invalidate its already planned rear goal.
    Point base={1800,960},station={251,1921};
    FallbackBoundary boundary{base,Length(station-base)};
    base={2200,960};
    assert(boundary.Contains(station,32));
    const FallbackBoundary shifted={base,boundary.radius};
    assert(!shifted.Contains(station,32));
    assert(boundary.Contains(boundary.anchor+Point{boundary.radius,0},.01f));
    assert(!boundary.Contains(boundary.anchor+Point{boundary.radius+33,0},32));
    // A new plan explicitly replaces both fields, including the relocated base.
    boundary={base,Length(station-base)};
    assert(boundary.Contains(station,32));
    // A ready missile 2 seconds away cannot hit during a .3-second shot.
    assert(ImpactVolleys(.3f,6.f,0.f,2.f)==0.f);
    assert(ImpactVolleys(.3f,6.f,0.f,0.f)>1.f); // a ready beam can
    assert(ImpactVolleys(.3f,6.f,4.f,2.2f)==1.f); // missile launched 2 s ago
    assert(ImpactVolleys(.3f,6.f,4.f,3.f)==0.f); // not yet in the window
    assert(ImpactVolleys(.3f,6.f,3.f,2.f)==0.f); // already passed
    assert(ImpactVolleys(2.f,1.f,.5f,4.f)==2.f); // two earlier salvos in flight
    // Concealment policy affects future acquisition, never an observed reload's
    // earlier projectiles. A zero policy weight still counts those salvos.
    assert(ImpactVolleys(.3f,6.f,4.f,2.2f,0.f)==1.f);
    assert(ImpactVolleys(2.f,1.f,.5f,4.f,.25f)==2.f);
    assert(ImpactVolleys(.3f,6.f,0.f,0.f,.25f)==ImpactVolleys(.3f,6.f,0.f,0.f)*.25f);
    assert(BeamIntensity(0,900,0)==1.f);
    assert(BeamIntensity(900,900,0)==.5f);
    assert(BeamIntensity(900,900,.8f)==.8f);
    assert(BeamIntensity(900,900,1)==1.f); // non-beam metadata preserves damage
    assert(BeamIntensity(-20,900,0)==1.f); // overlapping collision volumes
    assert(CollisionHits(40,520)==6.f);
    assert(!Survivable(3700,3700,1200*CollisionHits(40,520),.2f));
    assert(CollisionHits(0,520)==1.f);
    if(argc>1 && std::string(argv[1])=="--benchmark") {
        std::vector<Attacker> crowd; for(int i=0;i<400;++i) crowd.push_back({{value(rng)*.25f,value(rng)*.25f},100});
        float groupMetal=0;
        const auto groupStart=std::chrono::steady_clock::now();
        // Worst case: every observed attacker is a seed. 16 AIs x 100 decisions.
        for(int tick=0;tick<100;++tick) for(int ai=0;ai<16;++ai) groupMetal+=StrongestGroup(crowd,{},2000,400).metal;
        const auto groupMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-groupStart).count();
        std::cout<<"commander_fallback_group 16_AIs attackers=400 decisions=1600 milliseconds="<<groupMs<<" checksum="<<groupMetal<<"\n";
        contacts.clear(); for(int i=0;i<400;++i) contacts.push_back(Enemy(i,value(rng),value(rng)));
        float checksum=0;
        const auto start=std::chrono::steady_clock::now();
        // 16 AIs x 10 decisions/s x 10 seconds. Geometry only, no engine I/O.
        for(int tick=0;tick<100;++tick) for(int ai=0;ai<16;++ai)
            for(int candidate=0;candidate<60;++candidate) {
                const float angle=float(candidate)*.104719755f;
                checksum+=ScoreLine(contacts,{}, {std::cos(angle),std::sin(angle)},250,500,8,40,12).value;
            }
        const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        std::cout<<"commander_geometry 16_AIs contacts=400 decisions=1600 candidates=60 milliseconds="<<ms<<" checksum="<<checksum<<"\n";
    }
    std::cout<<"commander_combat_test passed\n";
}
