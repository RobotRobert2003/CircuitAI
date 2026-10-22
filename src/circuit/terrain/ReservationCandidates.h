#pragma once
#include <algorithm>
#include <set>
namespace circuit { namespace reservation_candidates {
// Persistent IDs tolerate erasure/insertion between asks. The caller owns a
// zone/definition (or group/definition) index; this visits at most budget IDs.
// -2 distinguishes incomplete traversal from a completely rejected small set.
template<class Accept>
int Next(const std::set<int>& ids, int& after, int budget, Accept&& accept) {
    const int count=std::min(int(ids.size()),std::clamp(budget,1,32));
    auto it=ids.upper_bound(after);
    for(int n=0;n<count;++n) {
        if(it==ids.end()) it=ids.begin();
        const int id=*it++; after=id;
        if(accept(id)) return id;
    }
    return count<int(ids.size()) ? -2 : -1;
}
} }
