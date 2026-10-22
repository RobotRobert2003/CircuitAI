#ifndef CIRCUIT_NAVAL_GEOMETRY_H
#define CIRCUIT_NAVAL_GEOMETRY_H

#include <algorithm>
#include <cmath>
#include <vector>

namespace circuit::naval {
struct SupportSite { float across, along; };
// A finite footprint grid, independent of engine callbacks. Rear and side
// pads are compact; the complete forward lane remains empty. Sort once per
// new harbor, never per builder ask. Tie order is explicit and reproducible.
inline std::vector<SupportSite> SupportSites(float width, float depth,
        float factoryWidth, float factoryDepth, float reach, float exitMargin)
{
    std::vector<SupportSite> sites;
    if (!std::isfinite(width + depth + factoryWidth + factoryDepth + reach + exitMargin)
        || width < 8 || depth < 8 || factoryWidth <= 0 || factoryDepth <= 0
        || reach <= 0 || reach > 2048 || exitMargin < 0) return sites;
    const int nx = int(reach / width), nz = int(reach / depth);
    for (int z = -nz; z <= nz; ++z) for (int x = -nx; x <= nx; ++x) {
        const float a=x*width, b=z*depth;
        if (a*a+b*b > reach*reach) continue;
        if (std::abs(a) < (factoryWidth+width)*.5f && std::abs(b) < (factoryDepth+depth)*.5f) continue;
        if (b+depth*.5f > factoryDepth*.5f
            && std::abs(a)-width*.5f < factoryWidth*.5f+exitMargin) continue;
        // Do not surround the departure mouth with a second wall of turrets.
        if (b > factoryDepth*.5f) continue;
        sites.push_back({a,b});
    }
    std::sort(sites.begin(),sites.end(),[](const auto& a,const auto& b) {
        const float da=a.across*a.across+a.along*a.along, db=b.across*b.across+b.along*b.along;
        if (da!=db) return da<db;
        if (a.along!=b.along) return a.along<b.along;
        return a.across<b.across;
    });
    return sites;
}
// Test the entire swept hull, not just a connected coarse water sector.
// The caller supplies current terrain elevation; no AI policy lives here.
template<class Elevation>
bool Corridor(float x, float z, int facing, float length, float halfWidth,
              float draft, Elevation elevation)
{
    if (!std::isfinite(x) || !std::isfinite(z) || !std::isfinite(length) || !std::isfinite(halfWidth) || !std::isfinite(draft)
        || length < 0 || halfWidth < 0 || draft <= 0 || facing < 0 || facing > 3) return false;
    const float dx = facing == 1 ? 1.f : facing == 3 ? -1.f : 0.f;
    const float dz = facing == 0 ? 1.f : facing == 2 ? -1.f : 0.f;
    const int rows = std::max(1, int(std::ceil(length / 8.f)));
    const int cols = std::max(1, int(std::ceil(2.f * halfWidth / 8.f)));
    for (int r = 0; r <= rows; ++r) {
        const float along = length * r / rows;
        for (int c = 0; c <= cols; ++c) {
            const float across = -halfWidth + 2.f * halfWidth * c / cols;
            const float y = elevation(x + dx * along + dz * across, z + dz * along - dx * across);
            if (!std::isfinite(y) || y > -draft) return false;
        }
    }
    return true;
}
}
#endif
