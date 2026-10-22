// Standalone comparison; no engine and no timed assertion thresholds.
#include "circuit/terrain/AlliedReservations.h"
#include "support/allied_reservations_legacy.h"
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>

using Clock = std::chrono::steady_clock;
using circuit::allied_layout::Rect;
volatile size_t observed = 0;

// Prevent repeated read-only queries being hoisted out of the measurement loop.
// Native production calls remain normally optimized/inlined.
template<class Index>
__attribute__((noinline, noipa)) bool Query(const Index& index, const Rect& r) {
    return index.OverlapsOther(0, {r.x1, r.z1, r.x2, r.z2});
}

template<class Index>
void Churn(const char* implementation, int side, int reads) {
    Index index;
    const int iterations = 1000;
    size_t hits = 0;
    const auto t0 = Clock::now();
    for (int i = 0; i < iterations; ++i) {
        index.Put(0, Index::ZONE, 0, {0, 0, side, side});
        index.Put(1, Index::SLOT, 1, {side - 2, side - 2, side, side});
        for (int j = 0; j < reads; ++j) {
            const int offset = j % (side - 8);
            hits += Query(index, {offset, 0, offset + 4, 4});
        }
        index.Erase(0, Index::ZONE, 0);
        index.Erase(1, Index::SLOT, 1);
    }
    observed = hits;
    if (hits) std::abort();
    const double ns = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / iterations;
    // This row measures a complete reserve/query/release transaction, not one query.
    std::cout << implementation << ",churn-" << side << "-reads-" << reads << ",2," << reads << ",0," << ns << ",0\n";
}

template<class Index>
void Run(const char* implementation, const std::string& scenario, int count) {
    Index index;
    auto t0 = Clock::now();
    for (int i = 0; i < count; ++i) {
        int owner = 0;
        Rect r{1 + i % 8, 1 + i % 8, 3 + i % 8, 3 + i % 8};
        if (scenario == "mixed-miss" && i % 2) { owner = 1; r = {24, 24, 28, 28}; }
        if (scenario == "foreign-hit") owner = 1;
        if (scenario == "scattered-miss") {
            owner = i % 8;
            const int x = (i % 512) * 2, z = (i / 512) * 2;
            r = {x, z, x + 1, z + 1};
        }
        index.Put(owner, Index::SLOT, i, {r.x1, r.z1, r.x2, r.z2});
    }
    const double putNs = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / count;
    const int queries = std::string(implementation) == "legacy" ? std::max(64, 500000 / count) : 500000;
    size_t hits = 0;
    t0 = Clock::now();
    for (int i = 0; i < queries; ++i) {
        const int offset = i % 2;
        const Rect q = scenario == "scattered-miss" ? Rect{1 + (i % 256) * 2, 1, 2 + (i % 256) * 2, 2}
                     : Rect{offset, offset, 12 + offset, 12 + offset};
        hits += Query(index, q);
    }
    const double queryNs = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / queries;
    observed = hits;
    if (hits != (scenario == "foreign-hit" ? size_t(queries) : 0)) std::abort();
    t0 = Clock::now();
    for (int owner = 0; owner < 8; ++owner) index.RemoveOwner(owner);
    const double eraseNs = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / count;
    if (index.Size() != 0 || index.OverlapsOther(99, {0, 0, 1024, 1024})) std::abort();
    std::cout << implementation << ',' << scenario << ',' << count << ',' << queries << ','
              << putNs << ',' << queryNs << ',' << eraseNs << '\n';
}

int main() {
    std::cout << "implementation,scenario,reservations,queries,put_ns_per_claim,query_ns,remove_ns_per_claim\n" << std::fixed << std::setprecision(2);
    for (const char* scenario : {"own-page", "mixed-miss", "foreign-hit", "scattered-miss"}) {
        for (int count : {100, 1000, 10000, 50000}) {
            Run<circuit::allied_layout_legacy::Reservations>("legacy", scenario, count);
            Run<circuit::allied_layout::Reservations>("occupancy", scenario, count);
        }
    }
    for (int side : {16, 64, 128}) for (int reads : {0, 1000}) {
        Churn<circuit::allied_layout_legacy::Reservations>("legacy", side, reads);
        Churn<circuit::allied_layout::Reservations>("occupancy", side, reads);
    }
}
