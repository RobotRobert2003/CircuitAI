// Frozen pre-D197 implementation, for differential tests and benchmarks only.
#ifndef CIRCUIT_ALLIED_RESERVATIONS_LEGACY_H
#define CIRCUIT_ALLIED_RESERVATIONS_LEGACY_H

#include <map>
#include <set>
#include <tuple>
#include <vector>

namespace circuit { namespace allied_layout_legacy {

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
    enum Kind { SLOT, ZONE };
    using Key = std::tuple<int, int, int>; // owner team, kind, local ID
    void Put(int owner, Kind kind, int id, const Rect& rect) {
        const Key key(owner, kind, id);
        Erase(owner, kind, id);
        if (!rect.Valid()) return;
        entries.emplace(key, rect);
        ForBuckets(rect, [&](const Bucket& b) { buckets[b].insert(key); });
    }
    void Erase(int owner, Kind kind, int id) {
        const Key key(owner, kind, id);
        const auto it = entries.find(key);
        if (it == entries.end()) return;
        ForBuckets(it->second, [&](const Bucket& b) {
            auto bin = buckets.find(b);
            if (bin == buckets.end()) return;
            bin->second.erase(key);
            if (bin->second.empty()) buckets.erase(bin);
        });
        entries.erase(it);
    }
    void RemoveOwner(int owner) {
        std::vector<Key> removed;
        for (const auto& e : entries) if (std::get<0>(e.first) == owner) removed.push_back(e.first);
        for (const auto& key : removed) Erase(owner, Kind(std::get<1>(key)), std::get<2>(key));
    }
    bool OverlapsOther(int owner, const Rect& rect) const {
        if (!rect.Valid()) return false;
        bool found = false;
        ForBuckets(rect, [&](const Bucket& b) {
            if (found) return;
            const auto bin = buckets.find(b);
            if (bin == buckets.end()) return;
            for (const Key& key : bin->second) {
                if (std::get<0>(key) != owner && entries.at(key).Overlaps(rect)) { found = true; break; }
            }
        });
        return found;
    }
    size_t Size() const { return entries.size(); }
private:
    using Bucket = std::pair<int, int>;
    static constexpr int bucketCells = 32;
    template<class Fn> static void ForBuckets(const Rect& r, Fn fn) {
        for (int z = r.z1 / bucketCells; z <= (r.z2 - 1) / bucketCells; ++z)
            for (int x = r.x1 / bucketCells; x <= (r.x2 - 1) / bucketCells; ++x) fn(Bucket(x, z));
    }
    std::map<Key, Rect> entries;
    std::map<Bucket, std::set<Key>> buckets;
};

}} // namespace circuit::allied_layout
#endif
