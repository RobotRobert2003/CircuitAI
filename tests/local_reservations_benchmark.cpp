#include "circuit/terrain/LocalReservations.h"

#include <chrono>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <map>

using Index = circuit::local_layout::Reservations;
using Rect = Index::Rect;
using Clock = std::chrono::steady_clock;
static volatile unsigned sink = 0;
static bool legacy(const std::map<int, Rect>& entries, const Rect& q, int ignore) {
    for (const auto& [id, r] : entries) {
        if (id == ignore) continue;
        if (r.x1 < q.x2 && q.x1 < r.x2 && r.z1 < q.z2 && q.z1 < r.z2) return true;
    }
    return false;
}
template<class Query> static double measure(Query query, int iterations, bool expected) {
    const auto start = Clock::now();
    unsigned answers = 0;
    for (int i = 0; i < iterations; ++i) { answers += query(i); std::atomic_signal_fence(std::memory_order_seq_cst); }
    if (answers != unsigned(expected ? iterations : 0)) std::exit(2);
    sink = answers;
    return std::chrono::duration<double, std::nano>(Clock::now() - start).count() / iterations;
}
int main() {
    std::puts("slots,case,legacy_ns,index_ns,cell_bytes");
    for (int n : {100, 1000, 5000, 20000}) {
        Index index;
        std::map<int, Rect> entries;
        for (int i = 0; i < n; ++i) {
            const int x = (i % 200) * 4, z = (i / 200) * 4;
            const Rect r{x, z, x + 2, z + 2};
            entries.emplace(i, r); index.PutSlot(i, r);
        }
        // Equivalent pure rectangle work; engine wrapper/footprint cost is
        // deliberately excluded, so this is not a whole-placement benchmark.
        for (int kind = 0; kind < 3; ++kind) {
            const bool hit = kind == 2;
            const auto query = [kind, n](int i) {
                const int x = ((i * 17) % std::min(n, 200)) * 4;
                const int z = ((n - 1) / 200) * 4;
                return kind == 0 ? Rect{x + 2, z + 2, x + 4, z + 4}
                    : kind == 1 ? Rect{0, 0, 2, 2} : Rect{x, 0, x + 2, 2};
            };
            const int ignore = kind == 1 ? 0 : -1;
            const int iterations = 10000;
            const double oldNs = measure([&](int i) { return legacy(entries, query(i), ignore); }, iterations, hit);
            const double newNs = measure([&](int i) { return index.OverlapsSlot(query(i), ignore); }, iterations, hit);
            std::printf("%i,%s,%.3f,%.3f,%zu\n", n, kind == 0 ? "miss" : kind == 1 ? "ignore-only" : "hit", oldNs, newNs, index.CellStorageBytes());
        }
        // Native retains the authoritative map AND maintains the derived
        // index. Include both writes in the new path to expose that cost.
        auto updated = entries;
        const auto replacement = [n](int i) {
            const int id = i % n;
            const int x = (id % 200) * 4, z = (id / 200) * 4 + (i / n) % 2;
            return Rect{x, z, x + 2, z + 2};
        };
        const double oldNs = measure([&](int i) { entries[i % n] = replacement(i); return false; }, 100000, false);
        const double newNs = measure([&](int i) {
            updated[i % n] = replacement(i);
            index.PutSlot(i % n, replacement(i));
            return false;
        }, 100000, false);
        // Observe both resulting maps and the derived index after timing, so
        // neither implementation's replacement writes can become dead stores.
        for (const auto& [id, expected] : entries) {
            const auto& actual = updated.at(id);
            if (expected.x1 != actual.x1 || expected.z1 != actual.z1
                    || expected.x2 != actual.x2 || expected.z2 != actual.z2
                    || !index.OverlapsSlot(expected) || index.OverlapsSlot(expected, id)) std::exit(3);
        }
        std::printf("%i,replace,%.3f,%.3f,%zu\n", n, oldNs, newNs, index.CellStorageBytes());
    }
}
