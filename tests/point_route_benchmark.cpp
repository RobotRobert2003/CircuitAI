#include "terrain/LaneSolver.h"
#include <chrono>
#include <iostream>
#include <cstdint>

// Compile against the pinned pre-change solver and candidate with identical
// -O3 flags. No engine, graphics, scripts or profiler overhead is measured.
// Output hashes must match before comparing time/expanded cells.
int main() {
    using namespace circuit::lane;
    for(int span: {8,48,180}) {
        Terrain t; t.gw=256;t.gh=256;
        const int n=t.gw*t.gh;
        t.height.assign(n,-100); t.surfaceSlope.assign(n,0); t.body8.assign(n,0);
        for(auto& p:t.pass) p.assign(n,1);
        Grid threat(n,0);
#ifndef ROUTE_LEGACY
        PointWorkspace workspace;
#endif
        Solver solver(t);
        std::uint64_t hash=14695981039346656037ull, points=0;
        const auto begin=std::chrono::steady_clock::now();
        for(int q=0;q<160;++q) {
            // Ten publication versions, sixteen queries each. Identical data
            // intentionally exercises safe version invalidation, not pointer ABA.
            Point a((32+.5f)*64,(0),(32+(q%32)+.5f)*64);
            Point b((32+span+.5f)*64,(0),(32+(q%32)+.5f)*64);
            const auto route=solver.PointRoute(a,b,L_NAVAL,threat,10,1,3,1000000
#ifndef ROUTE_LEGACY
                ,nullptr,&workspace,q/16+1
#endif
            );
            points+=route.size();
            for(int cell:route) { hash^=cell;hash*=1099511628211ull; }
        }
        const double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
        std::cout<<"{\"span\":"<<span<<",\"requests\":160,\"ms\":"<<ms<<",\"expanded\":"<<solver.Expanded()
            <<",\"points\":"<<points<<",\"hash\":"<<hash<<"}\n";
    }
}
