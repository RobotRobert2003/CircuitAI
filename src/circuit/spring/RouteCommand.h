#pragma once
#include <vector>

namespace circuit::routecommand {
struct Command {
    int id = 0, options = 0, timeout = -1;
    float x = 0, y = 0, z = 0;
    bool operator==(const Command&) const = default;
};
// A freshly projected route may omit already consumed waypoints. Match only
// an exact suffix, optionally dropping a zero-distance joining MOVE. Callers
// must separately validate ownership, mode, target and the actual live queue.
// No tolerance: even a small changed destination is a new tactical intent.
inline bool RemainingIntent(const std::vector<Command>& issued,
        const std::vector<Command>& proposed, float x, float y, float z, int shiftOption,
        size_t* retainedCount = nullptr) {
    size_t begin = 0;
    if (proposed.size() > 1 && proposed.front().x == x
        && proposed.front().y == y && proposed.front().z == z) begin = 1;
    const size_t count = proposed.size() - begin;
    if (count == 0 || count > issued.size()) return false;
    const size_t offset = issued.size() - count;
    for (size_t index = 0; index < count; ++index) {
        Command next = proposed[begin + index];
        const Command& previous = issued[offset + index];
        // The first surviving queued MOVE can retain SHIFT. No other option
        // differences are equivalent; original expiry is checked by LiveSuffix.
        if (index == 0 && next.options == 0 && previous.options == shiftOption)
            next.options = previous.options;
        next.timeout = previous.timeout;
        if (!(next == previous)) return false;
    }
    if (retainedCount != nullptr) *retainedCount = count;
    return true;
}
// Exact surviving suffix of our dispatch, including SHIFT and expiry. Caller
// separately proves task ownership and unchanged intent. O(Q), no allocation.
template<class Reader>
bool LiveSuffix(const std::vector<Command>& issued, int count, int frame, Reader read) {
    if (count <= 0 || static_cast<size_t>(count) > issued.size()) return false;
    const size_t offset = issued.size() - count;
    for (int i=0; i<count; ++i) {
        Command actual;
        const auto& expected = issued[offset+i];
        if (expected.timeout < frame || !read(i,actual) || actual != expected) return false;
    }
    return true;
}
}
