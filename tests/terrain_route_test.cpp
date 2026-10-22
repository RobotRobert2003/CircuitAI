#include "circuit/terrain/LaneSolver.h"
#include "circuit/terrain/TerrainCorridor.h"
#include "circuit/terrain/TerrainPublication.h"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <random>
#include <chrono>
using namespace circuit::lane;
static void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void PublicationRevision() {
    Grid a(64, 10.f), b=a;
    Check(HeightRevision(1,a,b)==1,"unchanged recycled terrain retains content revision");
    b[17]=11.f;
    auto revision=HeightRevision(1,a,b);
    Check(revision==2,"fine deformation increments revision");
    a=b; b[17]=10.f;
    Check(HeightRevision(revision,a,b)==3,"restored geometry does not reuse an old epoch");
    Check(HeightRevision(0,a,b)==0,"wrapped revision remains uncacheable");
    Check(HeightRevision(std::numeric_limits<std::uint64_t>::max(),a,b)==0,"wrap disables reuse");
    b.push_back(10.f);
    Check(HeightRevision(3,a,b)==4,"dimension changes invalidate");
    a[0]=std::numeric_limits<float>::quiet_NaN(); b=a;
    Check(HeightRevision(4,a,b)==5,"nonfinite snapshots fail closed");
    std::cout<<"terrain publication mutation and wrap checks passed\n";
}
// Frozen full-field point-query contract: the optimized query must return the
// identical ordered cell vector, including strict-cost ties and directed edges.
static std::vector<int> FullRoute(const Terrain& t, int origin, int goal, int cls,
        const Grid& threat, float land, float water, float weight, float ceiling,
        const std::vector<char>* obstacles = nullptr) {
    if (!t.pass[cls][origin] || !t.pass[cls][goal]) return {};
    Grid penalty(threat.size()), distance; std::vector<char> blocked(threat.size());
    for (size_t c=0;c<threat.size();++c) {
        float v=std::isfinite(threat[c]) ? std::max(0.f,threat[c]) : 1e9f;
        blocked[c]=(t.height[c]<0 && v>ceiling) || (obstacles && (*obstacles)[c]);
        penalty[c]=std::min(1e8f,(t.height[c]<0 ? water : land)+v*weight);
    }
    blocked[origin]=false; if(blocked[goal]) return {};
    std::vector<int> previous, result;
    Solver(t).DijkstraMulti({goal},penalty,cls,nullptr,distance,previous,true,0,&blocked);
    if(distance[origin]==std::numeric_limits<float>::max()) return {};
    for(size_t steps=0;steps<threat.size();++steps) {
        result.push_back(origin); if(origin==goal) return result;
        origin=previous[origin]; if(origin<0) break;
    }
    return {};
}
static void Differential() {
    Terrain t; t.gw=31;t.gh=23; const int n=t.gw*t.gh;
    t.height.resize(n);t.surfaceSlope.resize(n);t.body8.assign(n,0);t.edges.resize(n);
    for(auto& p:t.pass) p.resize(n);
    Grid threat(n); std::vector<char> obstacles(n); PointWorkspace ws;
    Grid joinDistance,fullDistance,uniform(n,1.f);
    std::vector<int> joinPrevious,fullPrevious; SearchWorkspace joinSearch;
    std::mt19937 rng(243);
    for(int fixture=0;fixture<80;++fixture) {
        for(int c=0;c<n;++c) {
            t.height[c]=int(rng()%400)-200;t.surfaceSlope[c]=(rng()%30)/100.f;
            t.edges[c]=fixture%2 ? static_cast<unsigned char>(rng()%256) : 255;
            threat[c]=(rng()%5)*.25f; obstacles[c]=rng()%23==0;
            for(auto& p:t.pass) p[c]=rng()%11!=0;
        }
        for(int k=0;k<70;++k) {
            int origin=rng()%n,goal=k%13==0 ? origin : rng()%n,cls=k%_LANE_CLASSES_;
            auto pos=[&](int c){return Point((c%t.gw+.5f)*64,0,(c/t.gw+.5f)*64);};
            float land=k%3+1.f,water=k%4+1.f,weight=k%2 ? 8.f : 0.f,ceiling=k%3*.5f;
            const auto* obs=k%2 ? &obstacles : nullptr;
            auto expected=FullRoute(t,origin,goal,cls,threat,land,water,weight,ceiling,obs);
            auto actual=Solver(t).PointRoute(pos(origin),pos(goal),cls,threat,land,water,weight,ceiling,obs,&ws,fixture+1);
            Check(actual==expected,"early-settle/cache differs from full-field oracle");
            Check(Solver(t).PointRoute(pos(origin),pos(goal),cls,threat,land,water,weight,ceiling,obs,&ws,fixture+1)==expected,"repeated cached route differs");
            // Lane joining uses the default preferShelf=true, uniform costs
            // and no blocked mask; compare its exact predecessor chain too.
            if (t.pass[cls][origin] && t.pass[cls][goal]) {
                Solver(t).DijkstraMulti({goal},uniform,cls,nullptr,fullDistance,fullPrevious);
                Solver(t).DijkstraMulti({goal},uniform,cls,nullptr,joinDistance,joinPrevious,
                    true,0,nullptr,0,true,nullptr,origin,&joinSearch);
                const bool reachable=fullDistance[origin]!=std::numeric_limits<float>::max();
                Check(reachable==(joinSearch.Seen(origin) && joinDistance[origin]!=std::numeric_limits<float>::max()),"lane join reachability");
                if (reachable) for (int c=origin;c>=0;c=fullPrevious[c]) {
                    Check(joinDistance[c]==fullDistance[c] && joinPrevious[c]==fullPrevious[c],"lane join ordered chain");
                    if(c==goal) break;
                }
            }
        }
    }
    // Generation wrap, changed dimensions, and an escaped blocked start must
    // not leave stale visited cells or mutate the next request's obstacles.
    ws.search.generation=std::numeric_limits<std::uint32_t>::max();
    ws.search.Begin(n); Check(ws.search.generation==1 && !ws.search.Seen(0),"generation wrap");
    ws.search.Begin(n+1);Check(!ws.search.Seen(n),"workspace resize");
    std::cout<<"5600 differential route cases (two executions each) passed\n";
}
static void ExactResultCache() {
    Terrain terrain; terrain.gw=20; terrain.gh=12;
    terrain.height.assign(240,-20); terrain.surfaceSlope.assign(240,0);
    terrain.body8.assign(240,0); for(auto& pass:terrain.pass) pass.assign(240,1);
    Grid threat(240,0); PointWorkspace workspace; Solver solver(terrain);
    const Point origin(96,0,96), goal(1120,0,672);
    auto query=[&](int movement, std::uint64_t publication, const std::vector<char>* obstacles=nullptr) {
        return solver.PointRoute(origin,goal,movement,threat,1,1,1,10,obstacles,&workspace,publication);
    };
    const auto expected=query(L_AMPH,1); const auto searches=solver.Searches();
    Check(!expected.empty(),"cache fixture route exists");
    Check(query(L_AMPH,1)==expected && solver.Searches()==searches,"exact hit must avoid Dijkstra");
    query(L_LAND,1); Check(solver.Searches()==searches+1,"movement class belongs to key");
    query(L_AMPH,2); Check(solver.Searches()==searches+2,"new threat publication must search");
    const auto beforeUnversioned=solver.Searches(); query(L_AMPH,0); query(L_AMPH,0);
    Check(solver.Searches()==beforeUnversioned+2,"unversioned input cannot cache results");
    std::vector<char> obstacles(240,0); query(L_AMPH,3,&obstacles);
    const auto beforeOverlay=solver.Searches(); obstacles[expected[expected.size()/2]]=1;
    const auto diverted=query(L_AMPH,3,&obstacles);
    Check(solver.Searches()==beforeOverlay+1 && diverted!=expected,"live obstacles bypass cache");
    const auto beforeCosts=solver.Searches(); query(L_AMPH,4);
    solver.PointRoute(origin,goal,L_AMPH,threat,1,2,1,10,nullptr,&workspace,4);
    Check(solver.Searches()==beforeCosts+2,"changed costs invalidate results");
    // A different immutable terrain instance must not inherit an equal-sized cache.
    Terrain replacement=terrain; Solver next(replacement);
    next.PointRoute(origin,goal,L_AMPH,threat,1,2,1,10,nullptr,&workspace,4);
    Check(next.Searches()==1,"terrain ownership invalidates results");
    // Disconnected but individually passable endpoints cache negative answers.
    for(int z=0;z<12;++z) replacement.pass[L_AMPH][z*20+10]=0;
    PointWorkspace disconnected; Solver blocked(replacement);
    Check(blocked.PointRoute(origin,goal,L_AMPH,threat,1,1,1,10,nullptr,&disconnected,5).empty(),"disconnected route");
    blocked.PointRoute(origin,goal,L_AMPH,threat,1,1,1,10,nullptr,&disconnected,5);
    Check(blocked.Searches()==1,"exact negative answer reused");
    PointWorkspace bounded;
    for(int cell=0;cell<90;++cell) {
        const Point endpoint((cell%20+.5f)*64,0,(cell/20+.5f)*64);
        solver.PointRoute(origin,endpoint,L_AMPH,threat,1,1,1,10,nullptr,&bounded,6);
    }
    Check(bounded.routes.size()==PointWorkspace::maximumCachedRoutes,"cache memory bounded");
    auto beforeEviction=solver.Searches();
    solver.PointRoute(origin,{32,0,32},L_AMPH,threat,1,1,1,10,nullptr,&bounded,6);
    Check(solver.Searches()==beforeEviction+1,"FIFO eviction recomputes valid result");
    // Paired exact-input component cost, preserving existing scratch/cost reuse
    // in both arms. Only completed-result reuse differs, not Dijkstra's oracle.
    auto measure=[&](bool reuse) {
        PointWorkspace retained; std::size_t cells=0;
        const auto start=std::chrono::steady_clock::now();
        for(int repeat=0;repeat<2000;++repeat) {
            if(!reuse) {retained.routes.clear();retained.routeOrder.clear();retained.nextRoute=0;}
            cells+=solver.PointRoute(origin,goal,L_AMPH,threat,1,1,1,10,nullptr,&retained,7).size();
        }
        Check(cells==expected.size()*2000,"cached benchmark path parity");
        return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    };
    const double uncached=measure(false), cached=measure(true);
    std::cout<<"Exact route cache 2000 queries: uncached_ms="<<uncached<<" cached_ms="<<cached<<"\n";
}
static void ScoutCoverage() {
    Terrain terrain; terrain.gw=20; terrain.gh=12;
    terrain.height.assign(240,10); terrain.surfaceSlope.assign(240,0); terrain.body8.assign(240,0);
    for (auto& pass:terrain.pass) pass.assign(240,1);
    Grid threat(240,0); std::vector<char> coverage(240,0); PointWorkspace workspace;
    const Point from(96,0,352), to(1184,0,352);
    // The only opening is at the end of a broad, two-cell-thick screen.
    for (int z=1;z<11;++z) for (int x=9;x<=10;++x) coverage[z*20+x]=1;
    auto route=Solver(terrain).PointRoute(from,to,L_BOT,threat,1,1,1,1e9f,&coverage,&workspace,0);
    Check(!route.empty(),"scout finds opening around broad weapon coverage");
    for (int cell:route) Check(!coverage[cell],"scout never crosses masked weapon coverage");
    for (int z=0;z<12;++z) for (int x=9;x<=10;++x) coverage[z*20+x]=1;
    Check(Solver(terrain).PointRoute(from,to,L_BOT,threat,1,1,1,1e9f,&coverage,&workspace,0).empty(),
          "fully screened backline has no safe crossing");
    coverage.assign(240,0);
    coverage[5*20+1]=coverage[5*20+2]=1;
    threat[5*20+1]=threat[5*20+2]=50;
    route=Solver(terrain).PointRoute(from,to,L_BOT,threat,1,1,1,1e9f,nullptr,&workspace,0);
    Check(!route.empty(),"soft escape can leave a covered starting region");
    Check(coverage[5*20+1] && coverage[5*20+2],"escape never mutates shared coverage");
    std::cout<<"scout hard-coverage and soft-escape contracts passed\n";
}
int main() {
    // D-312: air routing must treat known AA as an obstacle even over dry
    // ground, and retained solver scratch must observe a newly closed gap.
    {
        Terrain air; air.gw=20; air.gh=12;
        air.height.assign(240,10); air.surfaceSlope.assign(240,0); air.body8.assign(240,0);
        for (auto& pass:air.pass) pass.assign(240,1);
        Grid costs(240,0); std::vector<char> aa(240,0); PointWorkspace workspace;
        for (int z=1;z<11;++z) for (int x=8;x<12;++x) aa[z*20+x]=1;
        const Point start(96,0,352), end(1184,0,352);
        const auto detour=Solver(air).PointRoute(start,end,L_AIR,costs,1,1,0,1e9f,&aa,&workspace,0);
        Check(!detour.empty(),"carrier detours around AA on dry terrain");
        for (int cell:detour) Check(!aa[cell],"carrier excludes known AA cells");
        for (int z=0;z<12;++z) for (int x=8;x<12;++x) aa[z*20+x]=1;
        Check(Solver(air).PointRoute(start,end,L_AIR,costs,1,1,0,1e9f,&aa,&workspace,0).empty(),"new AA closes flight route");
        aa.assign(240,0);
        Check(!Solver(air).PointRoute(start,end,L_AIR,costs,1,1,0,1e9f,&aa,&workspace,0).empty(),"destroyed AA releases route");
        std::cout<<"carrier AA obstacle lifetime passed\n";
    }
    ScoutCoverage();
    PublicationRevision();
    ExactResultCache();
    Differential();
    Terrain t; t.gw=20; t.gh=12;
    t.height.assign(240,-100); t.surfaceSlope.assign(240,0); t.body8.assign(240,0);
    for (auto& pass:t.pass) pass.assign(240,1);
    Grid threat(240,0);
    Point start(96,0,352), end(1184,0,352);
    for (int z=0;z<12;++z) { t.height[z*20+1]=20; t.height[z*20+18]=20; }
    auto route=Solver(t).PointRoute(start,end,L_AMPH,threat,2.5f,1,8,0);
    Check(!route.empty(),"quiet water crossing");
    for (int z=2;z<10;++z) threat[z*20+10]=100;
    route=Solver(t).PointRoute(start,end,L_AMPH,threat,2.5f,1,8,0);
    Check(!route.empty(),"route around submarine threat");
    for (int c:route) Check(threat[c]==0,"route enters known water threat");
    for (int z=0;z<12;++z) threat[z*20+10]=100;
    Check(Solver(t).PointRoute(start,end,L_AMPH,threat,2.5f,1,8,0).empty(),"fully guarded water must fail closed");
    threat.assign(240,0); t.pass[L_AMPH][5*20+1]=0;
    Check(Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,0).empty(),"no snapping blocked origin");
    t.pass[L_AMPH][5*20+1]=1;
    Check(Solver(t).PointRoute({-1,0,0},end,L_AMPH,threat,1,1,0,0).empty(),"invalid endpoint");
    Check(Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,std::numeric_limits<float>::quiet_NaN()).empty(),"invalid threshold");
    t.height.assign(240,10);
    Check(!Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,0).empty(),"dry map raid remains valid");
    // A narrow cliff between otherwise passable cell centres must reject the edge.
    auto flat=[](float,float){return 10.f;};
    auto cliff=[](float x,float){return x>=28 && x<=36 ? 0.9f : 0.f;};
    Check(!TerrainCorridor(0,32,64,32,0,.412f,10000,false,flat,cliff),"fine cliff not hidden by valid endpoints");
    Check(TerrainCorridor(64,32,128,32,0,.412f,10000,false,flat,cliff),"flat corridor remains valid");
    Check(!TerrainCorridor(0,32,64,32,0,.412f,10000,false,[](float,float){return -100.f;},cliff),"seabed cliffs use loaded slope limit too");
    Check(!TerrainCorridor(16,32,16,32,24,.412f,10000,false,flat,cliff),"check footprint interior, not only corners");
    auto shore=[](float x,float){return x<32 ? -10.f : 10.f;};
    Check(!TerrainCorridor(16,32,64,32,8,.412f,10000,true,shore,[](float,float){return 0.f;}),"dry corridor cannot wade");
    // Forced edge wall with one ramp, including diagonal attempts.
    t.edges.assign(240,255);
    for (int z=0;z<11;++z) { t.edges[z*20+9]&=~(1|16|32);t.edges[z*20+10]&=~(2|64|128); }
    route=Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,0);
    Check(!route.empty(),"reachable ramp");
    bool ramp=false;for (int c:route) if (c/20==11) ramp=true;
    Check(ramp,"route must use ramp rather than cliff edge");
    t.edges.clear(); t.height.assign(240,10);
    for (int z=1;z<11;++z) for (int x=6;x<14;++x) t.height[z*20+x]=-10;
    route=Solver(t).PointRoute(start,end,L_AMPH,threat,1,6,0,0);
    for (int c:route) Check(t.height[c]>=0,"land preferred over short water shortcut");
    route=Solver(t).PointRoute(start,end,L_AMPH,threat,2.5f,1,0,0);
    bool water=false;for(int c:route) if(t.height[c]<0) water=true;
    Check(water,"legacy Marauder preference preserved");
    std::vector<char> obstacles(240,0);
    obstacles[5*20+10]=1;
    route=Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,0,&obstacles);
    Check(!route.empty(),"route around an allied factory");
    for (int c:route) Check(!obstacles[c],"allied factory waypoint excluded");
    obstacles[5*20+18]=1;
    Check(Solver(t).PointRoute(start,end,L_AMPH,threat,1,1,0,0,&obstacles).empty(),"reject formation slot inside allied factory");
    std::cout << "18 terrain route scenarios passed\n";
}
