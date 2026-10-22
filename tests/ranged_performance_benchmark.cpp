// D-221 exact old/new kernels. Run serially with games/builds stopped; this
// measures container/query work, not engine callbacks, FPS or network traffic.
#include "terrain/RangedGeometry.h"
#include "ranged_legacy_index.h"
#include <cassert>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <random>

using namespace circuit::ranged;
using Clock=std::chrono::steady_clock;
static volatile std::uint64_t sink=0;
template<class F> double Median(F&& operation) {
    std::vector<double> values;
    for(int i=0;i<7;++i) {
        const auto start=Clock::now(); const auto result=operation();
        values.push_back(std::chrono::duration<double,std::micro>(Clock::now()-start).count());
        sink=result;
    }
    std::sort(values.begin(),values.end()); return values[3];
}
static void Record(const char* phase,int n,double before,double after,int repeats) {
    std::cout<<"{\"kernel\":\""<<phase<<"\",\"units\":"<<n
        <<",\"iterations\":"<<repeats<<",\"old_us\":"<<before/repeats
        <<",\"new_us\":"<<after/repeats<<",\"speedup\":"<<before/after<<"}\n";
}
int main() {
    std::mt19937 rng(221);
    std::cout<<std::fixed<<std::setprecision(5);
    for(int n:{2000,5000,10000}) {
        std::vector<Point> points(n);
        for(auto& p:points) p={float(rng()%12000),float(rng()%12000)};
        ranged_reference::SpatialIndex old;
        SpatialIndex now; now.Configure(12288,12288);
        const auto rebuild=[&](auto& grid) {
            std::uint64_t total=0;
            for(int step=0;step<100;++step) {
                grid.Clear();
                for(int i=0;i<n;++i) grid.Add(points[i],i);
                grid.Query({6000,6000},7000,[&](int id){total=total*131+id;});
            }
            return total;
        };
        assert(rebuild(old)==rebuild(now));
        const double a=Median([&]{return rebuild(old);});
        const double b=Median([&]{return rebuild(now);});
        Record("rebuild-and-ordered-enumeration",n,a,b,100);
        const auto predicate=[&](int id){return id%17==0;};
        const auto oldQuery=[&] {
            std::uint64_t hits=0;
            for(int i=0;i<3000;++i) {
                bool found=false;
                old.Query({float(4000+i%1000),6000},7000,[&](int id){if(!found && predicate(id)) found=true;});
                hits+=found;
            }
            return hits;
        };
        const auto newQuery=[&] {
            std::uint64_t hits=0;
            for(int i=0;i<3000;++i) hits+=now.Any({float(4000+i%1000),6000},7000,predicate);
            return hits;
        };
        assert(oldQuery()==newQuery());
        Record("existence-hit",n,Median(oldQuery),Median(newQuery),3000);
        // A realistic local miss cannot benefit from early termination. Keep
        // this alongside the deliberately large existence-hit stress case so
        // the latter is not mistaken for a typical whole-decision speedup.
        const auto oldLocal=[&] {
            std::uint64_t visits=0;
            for(int i=0;i<3000;++i) {
                bool found=false;
                old.Query({float(4000+i%1000),6000},700,[&](int id){++visits;if(id<0) found=true;});
                visits+=found;
            }
            return visits;
        };
        const auto newLocal=[&] {
            std::uint64_t visits=0;
            for(int i=0;i<3000;++i) visits+=now.Any({float(4000+i%1000),6000},700,[&](int id){++visits;return id<0;});
            return visits;
        };
        assert(oldLocal()==newLocal());
        Record("local-existence-miss",n,Median(oldLocal),Median(newLocal),3000);
        const auto oldMiss=[&] {
            std::uint64_t visits=0;
            for(int i=0;i<1000;++i) old.Query({24000,24000},12000,[&](int){++visits;});
            return visits;
        };
        const auto newMiss=[&] {
            std::uint64_t visits=0;
            for(int i=0;i<1000;++i) now.Query({24000,24000},12000,[&](int){++visits;});
            return visits;
        };
        assert(oldMiss()==newMiss());
        Record("empty-bounds-query",n,Median(oldMiss),Median(newMiss),1000);
        OrderedIds sorter(32000);
        std::vector<int> source(32000); std::iota(source.begin(),source.end(),0);
        std::shuffle(source.begin(),source.end(),rng); source.resize(n);
        auto ids=source;
        const auto sortOld=[&] {
            for(int i=0;i<500;++i) {std::copy(source.begin(),source.end(),ids.begin());std::sort(ids.begin(),ids.end());}
            return ids[n/2];
        };
        const auto sortNew=[&] {
            for(int i=0;i<500;++i) {std::copy(source.begin(),source.end(),ids.begin());sorter.Sort(ids,n);}
            return ids[n/2];
        };
        assert(sortOld()==sortNew());
        Record("ascending-id-order",n,Median(sortOld),Median(sortNew),500);
    }
    return sink==std::uint64_t(-1);
}
