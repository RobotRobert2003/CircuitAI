#ifndef CIRCUIT_ALLIED_RESERVATIONS_H
#define CIRCUIT_ALLIED_RESERVATIONS_H

#include <algorithm>
#include <array>
#include <bit>
#include <cassert>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <tuple>
#include <vector>

namespace circuit { namespace allied_layout {

// Half-open cell rectangles. No engine or UnitDef ownership crosses AI instances.
struct Rect {
    int x1, z1, x2, z2;
    bool Valid() const { return x1 >= 0 && z1 >= 0 && x1 < x2 && z1 < z2; }
    bool Overlaps(const Rect& r) const {
        return x1 < r.x2 && r.x1 < x2 && z1 < r.z2 && r.z1 < z2;
    }
};

class Reservations {
public:
    // EXIT (D-343): a factory exit corridor, shared in addition to its ZONE
    // entry so teammates can keep the corridor's far end open for ships.
    enum Kind { SLOT, ZONE, EXIT };
    using Key = std::tuple<int, int, int>; // owner team, kind, local ID
    uint64_t Revision() const { return revision; }
    void Put(int owner, Kind kind, int id, const Rect& rect) {
        ++revision;
        Erase(owner, kind, id);
        if (!rect.Valid()) return;
        entries.emplace(Key(owner, kind, id), rect);
        ChangeCells(owner, rect, true);
    }
    void Erase(int owner, Kind kind, int id) {
        ++revision;
        const auto it = entries.find(Key(owner, kind, id));
        if (it == entries.end()) return;
        ChangeCells(owner, it->second, false);
        entries.erase(it);
    }
    void RemoveOwner(int owner) {
        ++revision;
        // Owner is the leading key: unrelated teams need not be scanned.
        auto it = entries.lower_bound(Key(owner, SLOT, std::numeric_limits<int>::min()));
        while (it != entries.end() && std::get<0>(it->first) == owner) {
            ChangeCells(owner, it->second, false);
            it = entries.erase(it);
        }
    }
    // O(footprint pages + occupied footprint cells), independent of claim count.
    // No map/hash lookup, allocation, or reservation traversal on this path.
    bool OverlapsOther(int owner, const Rect& rect) const {
        if (!rect.Valid()) return false;
        const int lastZ = std::min((rect.z2 - 1) / pageCells, int(pages.size()) - 1);
        for (int pz = rect.z1 / pageCells; pz <= lastZ; ++pz) {
            const auto& row = pages[pz];
            const int lastX = std::min((rect.x2 - 1) / pageCells, int(row.size()) - 1);
            for (int px = rect.x1 / pageCells; px <= lastX; ++px) {
                const auto& page = row[px];
                if (!page) continue;
                if (!page->fullOwners.empty()
                    && (page->fullOwners.size() > 1 || page->fullOwners.begin()->first != owner)) return true;
                const auto& partial = page->partial;
                if (!partial || (partial->owners.size() == 1 && partial->owners.begin()->first == owner)) continue;
                const Rect local = InPage(rect, px, pz);
                const uint32_t mask = (~uint32_t{0} << local.x1) & (~uint32_t{0} >> (pageCells - local.x2));
                for (int z = local.z1; z < local.z2; ++z) {
                    uint32_t occupied = partial->occupied[z] & mask;
                    if (occupied && partial->owners.size() == 1) return true;
                    while (occupied) {
                        const int x = std::countr_zero(occupied);
                        const Cell& cell = partial->cells[z * pageCells + x];
                        if (cell.owners > 1 || cell.ownerXor != owner) return true;
                        occupied &= occupied - 1;
                    }
                }
            }
        }
        return false;
    }
    size_t Size() const { return entries.size(); }
    // D-343: visit the rectangles of other owners' entries of one kind that
    // overlap a window. O(entries); used only by bounded, planning-time naval
    // path checks, never per frame.
    template <class Visit> void ForEachOther(int owner, Kind kind, const Rect& window, Visit&& visit) const {
        for (const auto& entry : entries) {
            if (std::get<0>(entry.first) != owner && std::get<1>(entry.first) == kind && entry.second.Overlaps(window))
                visit(entry.second);
        }
    }
private:
    uint64_t revision = 0;
    static constexpr int pageCells = 32;
    struct Cell {
        uint32_t owners = 0;
        int ownerXor = 0;
    };
    struct Coverage {
        std::array<uint32_t, pageCells * pageCells> counts{};
        int cells = 0;
    };
    struct PartialPage {
        std::array<Cell, pageCells * pageCells> cells{};
        std::array<uint32_t, pageCells> occupied{};
        // Mutations use the tree; size()/begin() are constant-time summaries.
        std::map<int, Coverage> owners;
    };
    struct Page {
        // Complete pages need no per-cell raster update or cell storage.
        std::map<int, uint32_t> fullOwners;
        std::unique_ptr<PartialPage> partial;
    };
    static Rect InPage(const Rect& r, int px, int pz) {
        const int x = px * pageCells, z = pz * pageCells;
        return {std::max(0, r.x1 - x), std::max(0, r.z1 - z),
                std::min(pageCells, r.x2 - x), std::min(pageCells, r.z2 - z)};
    }
    void ChangeCells(int owner, const Rect& rect, bool add) {
        const int lastZ = (rect.z2 - 1) / pageCells, lastX = (rect.x2 - 1) / pageCells;
        if (add && pages.size() <= size_t(lastZ)) pages.resize(size_t(lastZ) + 1);
        for (int pz = rect.z1 / pageCells; pz <= lastZ; ++pz) {
            auto& row = pages[pz];
            if (add && row.size() <= size_t(lastX)) row.resize(size_t(lastX) + 1);
            for (int px = rect.x1 / pageCells; px <= lastX; ++px) {
                auto& page = row[px];
                if (add && !page) page = std::make_unique<Page>();
                assert(page);
                const Rect local = InPage(rect, px, pz);
                if (local.x1 == 0 && local.z1 == 0 && local.x2 == pageCells && local.z2 == pageCells) {
                    auto it = add ? page->fullOwners.try_emplace(owner, 0).first : page->fullOwners.find(owner);
                    assert(it != page->fullOwners.end());
                    if (add) {
                        assert(it->second != std::numeric_limits<uint32_t>::max());
                        ++it->second;
                    } else {
                        assert(it->second > 0);
                        if (--it->second == 0) page->fullOwners.erase(it);
                    }
                    if (page->fullOwners.empty() && !page->partial) page.reset();
                    continue;
                }
                if (add && !page->partial) page->partial = std::make_unique<PartialPage>();
                assert(page->partial);
                auto& partial = *page->partial;
                auto it = add ? partial.owners.try_emplace(owner).first : partial.owners.find(owner);
                assert(it != partial.owners.end());
                Coverage& coverage = it->second;
                for (int z = local.z1; z < local.z2; ++z) {
                    for (int x = local.x1; x < local.x2; ++x) {
                        const int index = z * pageCells + x;
                        uint32_t& count = coverage.counts[index];
                        Cell& cell = partial.cells[index];
                        if (add) {
                            assert(count != std::numeric_limits<uint32_t>::max());
                            if (count++ == 0) {
                                ++coverage.cells;
                                ++cell.owners;
                                cell.ownerXor ^= owner;
                                partial.occupied[z] |= uint32_t{1} << x;
                            }
                        } else {
                            assert(count > 0);
                            if (--count == 0) {
                                --coverage.cells;
                                --cell.owners;
                                cell.ownerXor ^= owner;
                                if (cell.owners == 0) partial.occupied[z] &= ~(uint32_t{1} << x);
                            }
                        }
                    }
                }
                if (coverage.cells == 0) partial.owners.erase(it);
                if (partial.owners.empty()) page->partial.reset();
                if (page->fullOwners.empty() && !page->partial) page.reset();
            }
        }
    }
    std::map<Key, Rect> entries;
    std::vector<std::vector<std::unique_ptr<Page>>> pages;
};

}} // namespace circuit::allied_layout
#endif
