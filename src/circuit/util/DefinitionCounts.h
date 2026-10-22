#pragma once

#include <unordered_map>
#include <vector>
#include <cassert>
#include <algorithm>
#include <cstddef>

namespace circuit {
// Lifecycle index: O(1) count by dense UnitDef ID, average O(1) membership
// mutation. Store the definition with the key so removal never dereferences a
// dead task/unit. Duplicate notifications and ID/pointer reuse are idempotent.
// Only integer counts live here; float spending sums must retain their order.
template<class Key> class DefinitionCounts {
public:
    void Set(Key key, int definition) {
        if (definition < 0) { Erase(key); return; }
        auto [it, inserted] = members.emplace(key, definition);
        if (!inserted) {
            if (it->second == definition) return;
            --counts[it->second]; it->second = definition;
        }
        if (counts.size() <= static_cast<size_t>(definition)) counts.resize(definition + 1, 0);
        ++counts[definition];
    }
    void Erase(Key key) {
        auto it = members.find(key);
        if (it == members.end()) return;
        assert(counts[it->second] > 0);
        --counts[it->second]; members.erase(it);
    }
    int Count(int definition) const {
        return definition >= 0 && static_cast<size_t>(definition) < counts.size() ? counts[definition] : 0;
    }
    void Clear() { members.clear(); std::fill(counts.begin(), counts.end(), 0); }
private:
    std::unordered_map<Key, int> members;
    std::vector<int> counts;
};
} // namespace circuit
