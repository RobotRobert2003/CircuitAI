#ifndef CIRCUIT_TERRAIN_TERRAINPUBLICATION_H
#define CIRCUIT_TERRAIN_TERRAINPUBLICATION_H

#include <cstdint>
#include <limits>
#include <vector>

namespace circuit::lane {
// Exact content identity across recycled terrain buffers, not their addresses.
// Zero is permanently uncacheable after wrap. NaNs deliberately fail equality.
inline std::uint64_t HeightRevision(std::uint64_t previous,
        const std::vector<float>& before, const std::vector<float>& after)
{
    if (previous == 0) return 0;
    if (before == after) return previous;
    return previous == std::numeric_limits<std::uint64_t>::max() ? 0 : previous + 1;
}
}
#endif
