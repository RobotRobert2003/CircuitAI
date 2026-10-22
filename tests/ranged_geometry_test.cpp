#include "terrain/RangedGeometry.h"
#include "terrain/HeightMapGeometry.h"
#include "ranged_legacy_index.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <numeric>
#include <random>
#include <set>

using namespace circuit::ranged;
int main()
{
    // KI-571: projected firing positions at every edge/corner must sample a
    // valid cell; interior arithmetic and invalid-input rejection are exact.
    for (float x : {-10000.f, -1.f, 0.f, 15.5f, 31.5f, 32.f, 10000.f}) {
        for (float z : {-10000.f, -1.f, 0.f, 7.5f, 23.5f, 24.f, 10000.f}) {
            float boundedX=x, boundedZ=z;
            assert(circuit::terrain_geometry::BoundHeightPoint(boundedX,boundedZ,4,12,8));
            const int index=int(boundedZ)/8*4+int(boundedX)/8;
            assert(index>=0 && index<12);
            if(x>=0 && x<32 && z>=0 && z<24) assert(x==boundedX && z==boundedZ);
        }
    }
    for(float invalid : {std::numeric_limits<float>::quiet_NaN(),
            std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()}) {
        float x=invalid,z=1;
        assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,4,12,8));
        x=1; z=invalid;
        assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,4,12,8));
    }
    float x=1,z=1;
    assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,0,12,8));
    assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,4,0,8));
    assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,4,11,8));
    assert(!circuit::terrain_geometry::BoundHeightPoint(x,z,4,12,0));
    // Queue the exact formation slot without toggling off a nearby grid
    // endpoint. Recoil uses a strict 17-elmo positional cancellation radius.
    std::vector<Point> route;
    AppendExactGoal(route,Point{100,100});
    assert(route.size()==1 && route.back().x==100);
    AppendExactGoal(route,Point{116,100});
    assert(route.size()==1 && route.back().x==116);
    AppendExactGoal(route,Point{133,100});
    assert(route.size()==2 && route.front().x==116);
    AppendExactGoal(route,Point{133,100});
    assert(route.size()==2);
    AppendExactGoal(route,Point{143,110});
    assert(route.size()==2 && route.back().x==143 && route.back().z==110);
    route={{100,100},{132,100}};
    AppendExactGoal(route,Point{116,100});
    assert(route.size()==1 && route.back().x==116);
    // Safe endpoints alone must not permit a path through a defended area.
    assert(!SafeSegment({-200,0},{200,0},{0,0},100));
    assert(SafeSegment({-200,150},{200,150},{0,0},100));
    assert(SafeSegment({50,0},{150,0},{0,0},100));
    assert(!SafeSegment({50,0},{-150,0},{0,0},100));
    assert(!SafeSegment({50,0},{50,0},{0,0},100));
    assert(ClosingSpeed({0,0},{100,0},{-30,0})==30);
    assert(ClosingSpeed({0,0},{100,0},{30,0})==0);
    assert(EscapeSeconds(42,120,.007f,true,1)>EscapeSeconds(42,120,.007f,false,1));
    // A stationary forward hull at 120 angle units/frame needs ~9.1 seconds
    // for a half-turn, before the separate acceleration/reaction allowance.
    assert(std::fabs(EscapeSeconds(0,120,1,true,0)-32768.f/120.f/30.f)<.001f);
    assert(UsefulScore(1000,4000,1000,0,true,true,true,1)>
           UsefulScore(1000,4000,1000,4000,true,true,true,1));
    assert(UsefulScore(1000,4000,1000,0,true,true,true,1)>
           UsefulScore(1000,4000,1000,0,true,true,false,1));
    // Spatial lookup has an exact brute-force oracle, including negative
    // coordinates, mutation, reused IDs and clear/rebuild boundaries.
    std::mt19937 rng(207);
    std::uniform_real_distribution<float> coordinate(-8192,8192);
    std::vector<Point> points(4096);
    SpatialIndex index;
    assert(index.CanQuery({-100.f,100.f},1000.f));
    assert(!index.CanQuery({std::numeric_limits<float>::quiet_NaN(),0.f},1.f));
    assert(!index.CanQuery({0.f,0.f},std::numeric_limits<float>::infinity()));
    assert(!index.CanQuery({std::numeric_limits<float>::max(),0.f},1.f));
    assert(!index.CanQuery({0.f,0.f},-1.f));
    index.Configure(12288,12288);
    ranged_reference::SpatialIndex old;
    for(size_t i=0;i<points.size();++i) { points[i]={coordinate(rng),coordinate(rng)}; index.Add(points[i],int(i)); old.Add(points[i],int(i)); }
    for(int query=0;query<1000;++query) {
        Point p{coordinate(rng),coordinate(rng)}; float radius=64+(rng()%1500);
        std::set<int> expected,actual;
        for(size_t i=0;i<points.size();++i) if(DistanceSq(p,points[i])<=radius*radius) expected.insert(int(i));
        index.Query(p,radius,[&](int i) { if(DistanceSq(p,points[i])<=radius*radius) actual.insert(i); });
        assert(expected==actual);
        // Preserve ordered cell/insertion traversal, not only a set of hits:
        // equal target scores and floating sums depend on this exact sequence.
        std::vector<int> before,after;
        old.Query(p,radius,[&](int i){before.push_back(i);});
        index.Query(p,radius,[&](int i){after.push_back(i);});
        assert(before==after);
        int calls=0;
        const bool any=index.Any(p,radius,[&](int i){++calls;return DistanceSq(p,points[i])<=radius*radius;});
        assert(any==!expected.empty());
        assert(calls<=int(before.size()));
        const int changed=rng()%points.size();
        index.Remove(points[changed],changed); old.Remove(points[changed],changed);
        points[changed]={coordinate(rng),coordinate(rng)};
        index.Add(points[changed],changed); old.Add(points[changed],changed);
    }
    index.Clear(); int count=0; index.Query({0,0},20000,[&](int){++count;}); assert(count==0);
    // Empty/remove/re-add must not duplicate touched buckets or reorder IDs.
    for(int generation=0;generation<100;++generation) {
        index.Add({-1,-1},7); index.Remove({-1,-1},7); index.Add({-1,-1},8);
        index.Add({12288,12288},9); index.Add({16000,16000},10);
        std::vector<int> ids; index.Query({0,0},20000,[&](int i){ids.push_back(i);});
        assert((ids==std::vector<int>{8,9,10}));
        int visits=0; assert(index.Any({0,0},20000,[&](int){++visits;return true;})); assert(visits==1);
        index.Clear(); assert(!index.Any({0,0},20000,[](int){return true;}));
    }
    CellStore<float> sums; sums.Configure(96,96);
    sums.Get(-1,-1)+=3; sums.Get(95,95)+=4; sums.Get(95,95)+=5;
    assert(*sums.Find(-1,-1)==3 && *sums.Find(95,95)==9);
    sums.Clear(); assert(sums.Find(-1,-1)==nullptr); sums.Get(95,95)+=7; assert(*sums.Find(95,95)==7);
    sums.Configure(2000000,2000000); sums.Get(1700000,0)=2; assert(*sums.Find(1700000,0)==2); // sparse allocation fallback
    OrderedIds ordered(32000);
    std::vector<int> ids(32000); std::iota(ids.begin(),ids.end(),0);
    for(int size:{0,1,127,128,2000,5000,10000,32000}) {
        std::shuffle(ids.begin(),ids.end(),rng); auto sorted=ids;
        std::sort(sorted.begin(),sorted.begin()+size); ordered.Sort(ids,size); assert(ids==sorted);
    }
    // Duplicates and IDs outside the advertised engine bound preserve std::sort.
    for(int special:{-1,32000,0}) {
        std::iota(ids.begin(),ids.end(),0); ids[129]=special; auto sorted=ids;
        std::sort(sorted.begin(),sorted.begin()+256); ordered.Sort(ids,256); assert(ids==sorted);
    }
    // SEA static envelopes: different weapon reaches and negative margins
    // must retain the old strict boundary. Rebuild publications between rounds.
    SpatialIndex waterWeapons;
    struct WaterWeapon { Point point; float range; };
    for (int publication=0; publication<12; ++publication) {
        waterWeapons.Clear();
        std::vector<WaterWeapon> weapons;
        float largest=0;
        for (int index=0; index<200; ++index) {
            const float range=float(rng()%2400);
            weapons.push_back({{coordinate(rng),coordinate(rng)},range});
            waterWeapons.Add(weapons.back().point,index);
            largest=std::max(largest,range);
        }
        for (int query=0; query<300; ++query) {
            const Point point{coordinate(rng),coordinate(rng)};
            const float margin=float(int(rng()%1200)-600), formation=float(rng()%1000);
            const auto within=[&](int index) {
                const auto& weapon=weapons[index];
                const float radius=(weapon.range+margin)+formation;
                const float x=point.x-weapon.point.x,z=point.z-weapon.point.z;
                return x*x+z*z<radius*radius;
            };
            bool legacy=false;
            for (int index=0; index<int(weapons.size()); ++index) legacy=legacy || within(index);
            assert(waterWeapons.Any(point,(largest+std::fabs(margin))+std::fabs(formation),within)==legacy);
        }
    }
    // D-294: Fatboy (307 elmo/s shell, 150 splash) against a Tick (132 elmo/s,
    // radius 8) at full 700 range drifts ~301 elmos > 1.5*158: evasive.
    assert(Evasive(700.f,307.f/30.f,132.f,150.f,8.f,1.5f));
    // Closer shots arrive sooner: 400 elmos drifts ~172, inside the limit.
    assert(!Evasive(400.f,307.f/30.f,132.f,150.f,8.f,1.5f));
    // A slow assault hull (42 elmo/s) at full range is never evasive.
    assert(!Evasive(700.f,307.f/30.f,42.f,150.f,24.f,1.5f));
    // Stationary targets, beams/instant weapons and a disabled limit opt out.
    assert(!Evasive(700.f,307.f/30.f,0.f,150.f,8.f,1.5f));
    assert(!Evasive(700.f,0.f,132.f,150.f,8.f,1.5f));
    assert(!Evasive(700.f,307.f/30.f,132.f,150.f,8.f,0.f));
    assert(!Evasive(700.f,307.f/30.f,132.f,150.f,8.f,std::numeric_limits<float>::quiet_NaN()));
    // The threshold is strict and monotone in distance.
    assert(!Evasive(10.f*30.f*1.f,10.f,100.f,40.f,10.f,2.f)); // drift 100 == 2*(50)
    assert(Evasive(10.f*30.f*1.01f,10.f,100.f,40.f,10.f,2.f));
    // D-296: hazard disc painting matches a brute-force centre-in-disc oracle,
    // clips at every edge, keeps the maximum and rejects invalid input.
    {
        const int gw=20, gh=12; const float cs=64.f;
        std::mt19937 rng(296);
        std::uniform_real_distribution<float> coordinate(-400.f,1700.f), radius(1.f,700.f);
        for (int trial=0; trial<500; ++trial) {
            std::vector<float> grid(gw*gh,0.f), oracle(gw*gh,0.f);
            const float x=coordinate(rng), z=coordinate(rng), r=radius(rng);
            const int painted=PaintDisc(grid,gw,gh,cs,x,z,r,1.f);
            int expected=0;
            for (int c=0;c<gw*gh;++c) {
                const float dx=(c%gw+.5f)*cs-x, dz=(c/gw+.5f)*cs-z;
                if (dx*dx+dz*dz<=r*r) { oracle[c]=1.f; ++expected; }
            }
            assert(painted==expected && grid==oracle);
        }
        std::vector<float> grid(gw*gh,0.f);
        assert(PaintDisc(grid,gw,gh,cs,96.f,96.f,40.f,3.f)==1 && grid[1*gw+1]==3.f);
        assert(PaintDisc(grid,gw,gh,cs,96.f,96.f,40.f,2.f)==1 && grid[1*gw+1]==3.f); // max kept
        assert(PaintDisc(grid,gw,gh,cs,-5000.f,96.f,100.f,1.f)==0);                 // off grid
        assert(PaintDisc(grid,gw,gh,cs,std::numeric_limits<float>::quiet_NaN(),96.f,100.f,1.f)==0);
        assert(PaintDisc(grid,gw,gh,cs,96.f,96.f,std::numeric_limits<float>::infinity(),1.f)==0);
        assert(PaintDisc(grid,gw,gh,cs,96.f,96.f,0.f,1.f)==0);
        std::vector<float> small(3,0.f);
        assert(PaintDisc(small,gw,gh,cs,96.f,96.f,100.f,1.f)==0);                   // undersized grid
    }
    std::cout << "ranged geometry: ordered legacy/brute-force spatial oracle, early exits, generations, overflow, weapon envelopes and ID sort PASS\n";
}
