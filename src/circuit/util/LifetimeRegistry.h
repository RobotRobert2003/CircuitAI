#ifndef SRC_CIRCUIT_UTIL_LIFETIMEREGISTRY_H_
#define SRC_CIRCUIT_UTIL_LIFETIMEREGISTRY_H_

#include <cstdint>
#include <unordered_map>

namespace circuit {

// Simulation-thread only. Never dereferences a candidate address. Generations
// distinguish an old object from a replacement allocated at the same address.
// O(L) storage, average O(1) lookup/mutation (worst O(L)); allocation only on
// object creation. Owners must unregister before the object's storage is freed.
// Covered by task_lifetime_test, including address reuse and callback handover.
template<class T>
class LifetimeRegistry {
public:
    using Generation = std::uint64_t;
    Generation Insert(const T* object) { return live.emplace(object, ++next).first->second; }
    void Erase(const T* object) { live.erase(object); }
    Generation Find(const T* object) const {
        const auto found = live.find(object);
        return found == live.end() ? 0 : found->second;
    }
    bool Matches(const T* object, Generation generation) const {
        return generation != 0 && Find(object) == generation;
    }
private:
    std::unordered_map<const T*, Generation> live;
    Generation next = 0;
};

template<class T, class Lookup>
T* LiveReference(T* object, std::uint64_t generation, Lookup lookup)
{
    return generation != 0 && lookup(object) == generation ? object : nullptr;
}

// Preserve intrusive ownership while refusing expired inputs and avoiding a
// Release on stale storage. Kept here so real unit handovers are testable
// without the engine, rather than testing a parallel ownership model.
template<class T, class Lookup>
bool ReplaceLiveReference(T*& object, std::uint64_t& generation, T* replacement, Lookup lookup)
{
    const auto next = lookup(replacement);
    if (replacement != nullptr && next == 0) return false;
    T* previous = LiveReference(object, generation, lookup);
    if (replacement != nullptr) replacement->AddRef();
    object = replacement;
    generation = next;
    if (previous != nullptr) previous->Release();
    return true;
}

} // namespace circuit
#endif
