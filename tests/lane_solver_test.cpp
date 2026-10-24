#include "circuit/terrain/LaneSolver.h"
#include "circuit/terrain/LanePath.h"

#include <algorithm>
#include <future>
#include <iostream>
#include <limits>
#include <string>

using namespace circuit::lane;
static void Require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static Terrain Flat(int w = 24, int h = 16) {
    Terrain t;
    t.gw=w; t.gh=h;
    t.height.assign(w*h, 10.f); t.surfaceSlope.assign(w*h,0.f); t.body8.assign(w*h,-1);
    for (int c=0;c<_LANE_CLASSES_;++c) t.pass[c].assign(w*h,c!=L_NAVAL);
    return t;
}
static Request Input(const Terrain& t) {
    Request r;
    r.allyEnds={{32,10,float(t.gh/2*64+32)}};
    r.enemyEnds={{float((t.gw-1)*64+32),10,float(t.gh/2*64+32)}};
    r.airThreat.assign(t.height.size(),0.f); r.surfThreat=r.airThreat;
    r.highGroundRoutes=0; r.alternatives=1; r.mergeRadius=64;
    return r;
}
static bool Same(const std::vector<Route>& a, const std::vector<Route>& b) {
    if (a.size()!=b.size()) return false;
    for (std::size_t i=0;i<a.size();++i) {
        if (a[i].cells!=b[i].cells || a[i].cls!=b[i].cls || a[i].mask!=b[i].mask
            || a[i].length!=b[i].length || a[i].threat!=b[i].threat || a[i].choke!=b[i].choke
            || a[i].ascent!=b[i].ascent || a[i].descent!=b[i].descent) return false;
    }
    return true;
}
static void TestFlatRoutesAndMasks() {
    const auto t=Flat(); const auto r=Input(t);
    const auto lanes=Solver(t).Run(r);
    Require(lanes.size()==2,"flat terrain has shared ground and separate air lanes");
    Require(lanes[0].cls==L_LAND && !(lanes[0].mask&(1<<L_NAVAL)),"least capable ground classification");
    Require(lanes[0].length==23*64 && lanes[0].front==-1,"flat shortest route length and no threat front");
    for (const auto& l:lanes) {
        Require(l.zone.empty(),"merge scratch must not survive publication");
        for (int c:l.cells) Require(t.pass[l.cls][c],"route stays passable");
    }
}
static void TestNoCornerCuttingAndDisconnectedWater() {
    auto t=Flat(3,3); auto r=Input(t);
    for (auto& p:t.pass) p.assign(9,0);
    t.pass[L_LAND][0]=t.pass[L_LAND][4]=1;
    Grid d; std::vector<int> prev;
    Solver(t).DijkstraMulti({0},Grid(9,1.f),L_LAND,nullptr,d,prev);
    Require(d[4]==std::numeric_limits<float>::max(),"diagonal cannot cross blocked corners");
    t=Flat();r=Input(t);
    for (int z=0;z<t.gh;++z) for (int x=10;x<=12;++x) {
        const int c=z*t.gw+x;
        t.height[c]=-100;
        for (int k:{L_LAND,L_BOT,L_ALLTERRAIN}) t.pass[k][c]=0;
        t.pass[L_NAVAL][c]=1;t.body8[c]=0;
    }
    for (const auto& l:Solver(t).Run(r))
        Require(!(l.mask&(1<<L_ALLTERRAIN)),"walker route cannot bridge deep water");
}
static void TestThreatSnapshotAndParallelDeterminism() {
    auto t=std::make_shared<const Terrain>(Flat());
    auto safe=Input(*t), threatened=safe;
    for (int z=5;z<=10;++z) for (int x=8;x<=16;++x) threatened.airThreat[z*t->gw+x]=1000;
    const auto reference=Solver(*t).Run(threatened);
    const auto unchanged=Solver(*t).Run(safe);
    Require(reference.back().cells!=unchanged.back().cells,"air search avoids captured AA threat");
    std::vector<std::future<std::vector<Route>>> jobs;
    for (int i=0;i<8;++i) jobs.push_back(std::async(std::launch::async,[t,threatened] { return Solver(*t).Run(threatened); }));
    // Mutating the producer after enqueue must not alter any job's request.
    threatened.airThreat.assign(t->height.size(),0);
    for (auto& j:jobs) Require(Same(reference,j.get()),"worker results equal reference and stay isolated");
    Require(Same(unchanged,Solver(*t).Run(safe)),"another AI's threats do not leak into cached terrain");
}
static void TestCancellationAndGenerationAdmission() {
    JobGate gate;
    auto first=gate.Begin();Require(first!=0 && !gate.Begin(),"one job at a time");
    gate.Invalidate();Require(gate.Pending() && !gate.Begin(),"cancelled worker retains admission slot");
    Require(!gate.Finish(first) && !gate.Pending(),"cancelled result cannot publish");
    auto second=gate.Begin();Require(second>first,"new generation after cancellation");
    Require(!gate.Finish(first) && gate.Pending(),"late duplicate cannot clear newer job");
    Require(gate.Finish(second) && !gate.Finish(second),"publish exactly once");
    const auto t=Flat();const auto r=Input(t);
    std::atomic<bool> cancel{true}; bool caught=false;
    try { Solver(t,{},&cancel).Run(r); } catch (const Cancelled&) { caught=true; }
    Require(caught,"cancelled queued job performs no search");
    cancel=false; Require(!Solver(t,{},&cancel).Run(r).empty(),"subsequent job still works");
}
static void TestMountainSpecialistRoute() {
    auto t=Flat(64,24);auto r=Input(t);
    // A broad upper shelf with a walker-only cliff between it and the valley.
    for (int z=0;z<t.gh;++z) for (int x=4;x<t.gw-4;++x) {
        const int c=z*t.gw+x;
        const bool cliff = x==4 || x==t.gw-5;
        t.height[c]=cliff ? 200.f : 400.f;
        if (cliff) {
            t.surfaceSlope[c]=0.9f;
            for (int k:{L_LAND,L_BOT,L_AMPH,L_HOVER}) t.pass[k][c]=0;
        }
    }
    r.highGroundRoutes=3;r.highGroundDetour=4;r.settings.cliffApproachClass=L_BOT;
    r.settings.cliffMinDrop=128;r.settings.cliffMinProgress=0.7f;
    r.settings.mountainSurfaceWeight=0.1f; // retain shelf exploration on a synthetic vertical step
    const auto routes=Solver(t).Run(r);
    bool found=false;
    for (const auto& route:routes) if (route.cls==L_ALLTERRAIN) {
        found=true;
        Require(!(route.mask&(1<<L_BOT)),"mountain flank excludes ordinary bots");
        Require(std::any_of(route.cells.begin(),route.cells.end(),[&](int c){return t.height[c]>=400;}),"flank reaches upper shelf");
        auto cells=route.cells;std::sort(cells.begin(),cells.end());
        Require(std::adjacent_find(cells.begin(),cells.end())==cells.end(),"specialist route has no loop");
    }
    Require(found,"high-ground component produces a specialist alternative");
}
static void TestIsolatedHillsAreNotStrategicLanes() {
    auto t=Flat(64,24); auto r=Input(t);
    // Several separated steep mesas beside otherwise connected flat ground.
    // Their combined extent is large, but no individual mountain is a flank.
    for (int start : {8,26,44}) for (int z=7;z<=16;++z) for (int x=start;x<start+8;++x) {
        const int c=z*t.gw+x;
        t.height[c]=400.f;
        for (int k : {L_LAND,L_BOT,L_AMPH,L_HOVER}) t.pass[k][c]=0;
    }
    r.alternatives=3;r.highGroundRoutes=3;r.highGroundDetour=8;r.specialistBias=3;
    auto loose=r;loose.settings.specialistMinSpan=0;loose.settings.specialistSpanFraction=0;
    const auto old=Solver(t).Run(loose);
    Require(std::any_of(old.begin(),old.end(),[](const Route& l){return l.cls==L_ALLTERRAIN;}),"fixture exposes the isolated-hill false positive");
    const auto filtered=Solver(t).Run(r);
    Require(std::none_of(filtered.begin(),filtered.end(),[](const Route& l){return l.cls==L_ALLTERRAIN;}),"isolated hills cannot be added together into a mountain flank");
    Require(std::any_of(filtered.begin(),filtered.end(),[](const Route& l){return l.cls==L_LAND;}),"ordinary land routes remain available");
    std::swap(r.allyEnds,r.enemyEnds);
    const auto reverse=Solver(t).Run(r);
    Require(std::none_of(reverse.begin(),reverse.end(),[](const Route& l){return l.cls==L_ALLTERRAIN;}),"qualification is symmetric for the two sides");
}
static void TestVisitingTwoEndsIsNotTraversingMountain() {
    auto t=Flat(64,24);
    for (int z=0;z<7;++z) for (int x=0;x<t.gw;++x) t.height[z*t.gw+x]=400;
    Route shortcut;shortcut.mask=1<<L_ALLTERRAIN;
    shortcut.cells={12*64,6*64,6*64+4,12*64+4,12*64+58,6*64+58,6*64+63,12*64+63};
    Require(!Solver(t).HasMountainTraverse(shortcut,128),"two visits connected through valley do not constitute a mountain traverse");
    Route traverse;traverse.mask=1<<L_ALLTERRAIN;traverse.cells.push_back(12*64);
    for (int x=0;x<64;++x) traverse.cells.push_back(6*64+x);
    traverse.cells.push_back(12*64+63);
    Require(Solver(t).HasMountainTraverse(traverse,128),"continuous progress on the same mountain qualifies");
    std::reverse(traverse.cells.begin(),traverse.cells.end());
    Require(Solver(t).HasMountainTraverse(traverse,128),"mountain traverse qualifies in reverse");
}
static void TestInputValidationAndClearance() {
    auto t=Flat();auto r=Input(t);r.airThreat.clear();bool caught=false;
    try { Solver(t).Run(r); } catch (const std::invalid_argument&) { caught=true; }
    Require(caught,"incomplete threat snapshot rejected");
    t.pass[L_AIR].clear();caught=false;
    try { Solver s(t); } catch (const std::invalid_argument&) { caught=true; }
    Require(caught,"incomplete terrain snapshot rejected");
    std::vector<int> clearance;
    Solver::Clearance(5,5,std::vector<char>(25,1),clearance);
    Require(clearance[12]==3 && clearance[0]==1,"open map edges bound corridor clearance");
}
static void TestDistributedCoverage() {
    Path bend;bend.Set({{0,0,0},{100,0,0},{100,0,100}});
    Require(bend.Length()==200 && bend.At(150).z==50,"lane advance follows bends by path distance");
    const auto projected=bend.Project({120,0,60});
    Require(projected.progress==160 && projected.distance==20,"commander corridor projection follows assigned segment");
    bend.Set({});Require(bend.Length()==0 && bend.At(10).x<0,"role change clears lane ownership");
    auto t=Flat(64,33);
    const Point start(32,10,1056),end(4064,10,1056);
    auto route=[&](float share,const std::vector<Point>& mex=std::vector<Point>{}) {
        return Solver(t).DistributedRoute(start,end,start,end,L_LAND,share,3,.15f,32.f,2.f,mex);
    };
    auto at=[&](const std::vector<int>& path,int x) {
        const auto found=std::find_if(path.begin(),path.end(),[&](int c){return c%t.gw==x;});
        Require(found!=path.end(),"coverage route crosses each longitudinal section");return *found/t.gw;
    };
    auto left=route(1.f/6),middle=route(.5f),right=route(5.f/6);
    Require(!left.empty() && !right.empty(),"distributed open routes exist");
    // Axis points east; positive lateral is south.
    Require(at(left,32)<at(middle,32)-6 && at(right,32)>at(middle,32)+6,"open ground is shared instead of all seats taking centre");
    Require(std::abs((at(middle,32)-at(left,32))-(at(right,32)-at(middle,32)))<=2,"open spacing symmetric within grid tolerance");
    for(int x=27;x<=36;++x) for(int z=0;z<t.gh;++z) if(z<15 || z>17)t.pass[L_LAND][z*t.gw+x]=0;
    left=route(1.f/6);right=route(5.f/6);
    Require(std::abs(at(right,32)-at(left,32))<=2,"lanes compress through shared choke");
    Require(at(right,47)-at(left,47)>12,"lanes fan back out beyond choke");
    for(int c:left)Require(t.pass[L_LAND][c],"coverage never crosses blocked terrain");
    t=Flat(64,33);
    const auto weighted=route(.5f,{{1568,10,1184},{2080,10,1184},{2592,10,1184}});
    Require(at(weighted,32)>at(route(.5f),32),"nearby mex clusters attract route within seat tolerance");
    for(auto& p:t.pass)p.assign(t.height.size(),0);
    t.pass[L_NAVAL].assign(t.height.size(),1);t.height.assign(t.height.size(),-100);
    const auto sea=Solver(t).DistributedRoute(start,end,start,end,L_NAVAL,1.f/6,3,.15f,32.f,0.f,{});
    Require(!sea.empty() && at(sea,32)<10,"same coverage geometry generates naval lanes");
    for(int z=0;z<t.gh;++z)t.pass[L_NAVAL][z*t.gw+30]=0;
    Require(Solver(t).DistributedRoute(start,end,start,end,L_NAVAL,.5f,3,.15f,32.f,0.f,{}).empty(),"disconnected water has no invented route");
}
int main() {
    try {
        TestDistributedCoverage();TestFlatRoutesAndMasks();TestNoCornerCuttingAndDisconnectedWater();
        TestThreatSnapshotAndParallelDeterminism();TestCancellationAndGenerationAdmission();
        TestInputValidationAndClearance();TestMountainSpecialistRoute();TestIsolatedHillsAreNotStrategicLanes();TestVisitingTwoEndsIsNotTraversingMountain();
        std::cout << "lane_solver_test: 9 suites passed (including distributed coverage and 8 concurrent solvers)\n";
    } catch (const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
