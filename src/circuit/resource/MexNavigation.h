#pragma once

#include <cmath>
#include <functional>
#include <limits>
#include <queue>
#include <utility>
#include <vector>

namespace circuit::mex_navigation {
constexpr float Unreachable = std::numeric_limits<float>::infinity();

inline bool Protected(int frame, int untilFrame) { return frame < untilFrame; }
inline bool Better(float distance, int team, float best, int owner) {
    return std::isfinite(distance) && (distance < best || (distance == best && (owner < 0 || team < owner)));
}
inline bool InBuildRange(float dx, float dy, float dz, float range) {
    return std::isfinite(dx) && std::isfinite(dy) && std::isfinite(dz)
        && std::isfinite(range) && range >= 0.f && dx*dx + dy*dy + dz*dz <= range*range;
}

// One terrain-only field per starting team and terrain publication. No enemy
// observations, mutable units or engine callbacks enter the solver. O(G log G)
// time / O(G) storage, eight edges per cell, with no diagonal corner cutting.
// Reused across mex asks; mex_navigation_test covers detours and disconnected hills.
template<class Passable, class Cost>
std::vector<float> Distances(int width, int height, int start, float initial,
        Passable passable, Cost cost) {
    const int size = width * height;
    std::vector<float> distance(size, Unreachable);
    if (start < 0 || start >= size || !passable(start)) return distance;
    using Item = std::pair<float, int>;
    std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pending;
    distance[start] = initial;
    pending.emplace(initial, start);
    while (!pending.empty()) {
        const auto [value, cell] = pending.top(); pending.pop();
        if (value != distance[cell]) continue;
        const int x = cell % width, z = cell / width;
        for (int dz = -1; dz <= 1; ++dz) for (int dx = -1; dx <= 1; ++dx) {
            const int nx = x + dx, nz = z + dz;
            if ((!dx && !dz) || nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
            const int next = nz * width + nx;
            if (!passable(next) || (dx && dz && (!passable(z*width+nx) || !passable(nz*width+x)))) continue;
            const float candidate = value + cost(cell, next);
            if (candidate < distance[next]) { distance[next] = candidate; pending.emplace(candidate, next); }
        }
    }
    return distance;
}
}
