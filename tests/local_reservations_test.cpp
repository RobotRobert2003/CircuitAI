#include "circuit/terrain/LocalReservations.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>

using Index = circuit::local_layout::Reservations;
using Rect = Index::Rect;
static int checks = 0;
static void check(bool condition) {
    ++checks;
    if (!condition) { std::fprintf(stderr, "local reservation check %i failed\n", checks); std::exit(1); }
}
static bool overlap(const Rect& a, const Rect& b) {
    return a.x1 < b.x2 && b.x1 < a.x2 && a.z1 < b.z2 && b.z1 < a.z2;
}
static bool oracle(const std::map<int, Rect>& entries, const Rect& query, int ignore = -1) {
    if (!query.Valid()) return false;
    for (const auto& [id, rect] : entries) if (id != ignore && overlap(rect, query)) return true;
    return false;
}
static void test_ignore_consumed_and_nested_zone_release() {
    Index index;
    index.PutSlot(1, {30, 30, 34, 34});
    check(index.OverlapsSlot({29, 29, 31, 31}));
    check(!index.OverlapsSlot({30, 30, 34, 34}, 1));
    check(!index.OverlapsSlot({34, 30, 38, 34}));
    index.PutSlot(2, {31, 31, 32, 32});
    check(index.OverlapsSlot({30, 30, 34, 34}, 1));
    index.EraseSlot(2); // consumed/served slots leave only the blocking-map marks
    check(!index.OverlapsSlot({30, 30, 34, 34}, 1));
    index.PutZone(1, {0, 0, 64, 64});
    index.PutZone(2, {16, 16, 48, 48});
    index.EraseZone(1);
    check(index.OverlapsZone({31, 31, 33, 33}));
    check(!index.OverlapsZone({0, 0, 16, 16}));
    index.EraseZone(2);
    check(!index.OverlapsZone({30, 30, 34, 34}));
    check(index.OverlapsSlot({30, 30, 34, 34}));
    index.PutSlot(1, {500, 500, 502, 502}); // replacement frees old pages
    check(!index.OverlapsSlot({30, 30, 34, 34}));
    index.EraseSlot(1);
    index.EraseSlot(1); // cancellation and teardown are idempotent
    check(index.CellStorageBytes() == 0);
}
static void test_random_lifecycle_and_reconstruction() {
    Index index;
    std::map<int, Rect> slots, zones;
    std::mt19937 rng(1992026);
    for (int step = 0; step < 25000; ++step) {
        const int id = int(rng() % 200);
        const bool zone = rng() % 4 == 0;
        auto& entries = zone ? zones : slots;
        const int x = int(rng() % 128), z = int(rng() % 128);
        const Rect rect{x, z, x + 1 + int(rng() % 35), z + 1 + int(rng() % 35)};
        if (rng() % 3 == 0) {
            entries.erase(id);
            if (zone) index.EraseZone(id); else index.EraseSlot(id);
        } else {
            entries.insert_or_assign(id, rect);
            if (zone) index.PutZone(id, rect); else index.PutSlot(id, rect);
        }
        for (int q = 0; q < 4; ++q) {
            const int qx = int(rng() % 180), qz = int(rng() % 180);
            const Rect query{qx, qz, qx + 1 + int(rng() % 8), qz + 1 + int(rng() % 8)};
            const int ignore = q == 0 ? id : -1;
            check(index.OverlapsSlot(query, ignore) == oracle(slots, query, ignore));
            check(index.OverlapsZone(query) == oracle(zones, query));
        }
        if (step % 997 == 0) {
            index.Clear(); // mirrors save/load and role reset without serialized cache state
            check(!index.OverlapsSlot({0, 0, 200, 200}));
            for (const auto& [slot, r] : slots) index.PutSlot(slot, r);
            for (const auto& [zon, r] : zones) index.PutZone(zon, r);
        }
    }
    index.Clear();
    check(index.CellStorageBytes() == 0);
}
int main() {
    test_ignore_consumed_and_nested_zone_release();
    test_random_lifecycle_and_reconstruction();
    std::printf("local reservations: %i checks, 0 failures\n", checks);
}
