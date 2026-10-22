#ifndef CIRCUIT_LOCAL_RESERVATIONS_H
#define CIRCUIT_LOCAL_RESERVATIONS_H

#include <algorithm>
#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <vector>

namespace circuit::local_layout {

// Exact half-open occupancy of unconsumed local slots and complete zone
// envelopes. The blocking map still owns terrain, yards and zone authority.
// Queries are O(footprint cells), independent of the number of reservations.
// This moves work to Put/Erase: O(log N + changed cells), with sparse 32x32
// pages plus the ID maps. Counts, not XOR alone, preserve overlapping owners
// when ignoring one slot. Every consume/release/load writer must update here.
// See tests/local_reservations_test.cpp and doc/performance/engineering-guide.md;
// this contract does not make the surrounding placement candidate search O(1).
class Reservations {
public:
    struct Rect {
        int x1, z1, x2, z2;
        bool Valid() const { return x1 >= 0 && z1 >= 0 && x2 > x1 && z2 > z1; }
    };

    void PutSlot(int id, const Rect& rect) { Put(slots, id, rect, false); }
    void PutZone(int id, const Rect& rect) { Put(zones, id, rect, true); }
    void EraseSlot(int id) { Erase(slots, id, false); }
    void EraseZone(int id) { Erase(zones, id, true); }
    void Clear() { slots.clear(); zones.clear(); pages.clear(); }

    [[nodiscard]] bool OverlapsSlot(const Rect& rect, int ignoreId = -1) const {
        return Any(rect, [ignoreId](const Cell& cell) {
            return cell.slots > 1 || (cell.slots == 1 && cell.slotXor != idBits(ignoreId));
        });
    }
    [[nodiscard]] bool OverlapsZone(const Rect& rect) const {
        return Any(rect, [](const Cell& cell) { return cell.zones != 0; });
    }
    [[nodiscard]] std::size_t CellStorageBytes() const {
        std::size_t count = 0;
        for (const auto& row : pages) for (const auto& page : row) if (page) ++count;
        return count * sizeof(Page);
    }

private:
    static constexpr int pageCells = 32;
    struct Cell {
        uint32_t slots = 0;
        uint32_t slotXor = 0;
        uint32_t zones = 0;
    };
    struct Page {
        std::array<Cell, pageCells * pageCells> cells{};
        std::size_t occupied = 0;
    };
    using Entries = std::map<int, Rect>;
    Entries slots;
    Entries zones;
    std::vector<std::vector<std::unique_ptr<Page>>> pages;

    static uint32_t idBits(int id) { return static_cast<uint32_t>(id); }
    void Put(Entries& entries, int id, const Rect& rect, bool zone) {
        Erase(entries, id, zone);
        if (!rect.Valid()) return;
        entries.emplace(id, rect);
        Change(rect, id, zone, true);
    }
    void Erase(Entries& entries, int id, bool zone) {
        const auto it = entries.find(id);
        if (it == entries.end()) return;
        Change(it->second, id, zone, false);
        entries.erase(it);
    }
    void Change(const Rect& rect, int id, bool zone, bool add) {
        const int lastZ = (rect.z2 - 1) / pageCells;
        const int lastX = (rect.x2 - 1) / pageCells;
        if (add && pages.size() <= std::size_t(lastZ)) pages.resize(std::size_t(lastZ) + 1);
        for (int pz = rect.z1 / pageCells; pz <= lastZ; ++pz) {
            auto& row = pages[pz];
            if (add && row.size() <= std::size_t(lastX)) row.resize(std::size_t(lastX) + 1);
            for (int px = rect.x1 / pageCells; px <= lastX; ++px) {
                auto& page = row[px];
                if (add && !page) page = std::make_unique<Page>();
                assert(page);
                for (int z = std::max(rect.z1, pz * pageCells); z < std::min(rect.z2, (pz + 1) * pageCells); ++z) {
                    for (int x = std::max(rect.x1, px * pageCells); x < std::min(rect.x2, (px + 1) * pageCells); ++x) {
                        Cell& cell = page->cells[(z % pageCells) * pageCells + x % pageCells];
                        const bool wasOccupied = cell.slots != 0 || cell.zones != 0;
                        uint32_t& count = zone ? cell.zones : cell.slots;
                        if (add) { assert(count != UINT32_MAX); ++count; }
                        else { assert(count > 0); --count; }
                        if (!zone) cell.slotXor ^= idBits(id);
                        const bool occupied = cell.slots != 0 || cell.zones != 0;
                        if (!wasOccupied && occupied) ++page->occupied;
                        else if (wasOccupied && !occupied) --page->occupied;
                    }
                }
                if (page->occupied == 0) page.reset();
            }
        }
    }
    template<class Predicate>
    bool Any(const Rect& rect, Predicate predicate) const {
        if (!rect.Valid()) return false;
        const int lastZ = std::min((rect.z2 - 1) / pageCells, int(pages.size()) - 1);
        for (int pz = rect.z1 / pageCells; pz <= lastZ; ++pz) {
            const auto& row = pages[pz];
            const int lastX = std::min((rect.x2 - 1) / pageCells, int(row.size()) - 1);
            for (int px = rect.x1 / pageCells; px <= lastX; ++px) {
                const auto& page = row[px];
                if (!page) continue;
                for (int z = std::max(rect.z1, pz * pageCells); z < std::min(rect.z2, (pz + 1) * pageCells); ++z) {
                    for (int x = std::max(rect.x1, px * pageCells); x < std::min(rect.x2, (px + 1) * pageCells); ++x) {
                        if (predicate(page->cells[(z % pageCells) * pageCells + x % pageCells])) return true;
                    }
                }
            }
        }
        return false;
    }
};

} // namespace circuit::local_layout
#endif
