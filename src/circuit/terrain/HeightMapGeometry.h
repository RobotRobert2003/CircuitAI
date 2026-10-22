#ifndef CIRCUIT_HEIGHT_MAP_GEOMETRY_H
#define CIRCUIT_HEIGHT_MAP_GEOMETRY_H

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace circuit::terrain_geometry {
// Projected combat points are not engine positions: they may cross map edges.
// Correct the point itself, not only its sample index, so subsequent threat and
// weapon calculations use the same position. O(1), no allocation or callbacks;
// finite interior coordinates remain bit-for-bit unchanged. Validate before
// float-to-integer conversion (NaN/infinity conversion is undefined).
inline bool BoundHeightPoint(float& positionX, float& positionZ,
                            int width, std::size_t sampleCount, int squareSize)
{
    if (!std::isfinite(positionX) || !std::isfinite(positionZ)
        || width <= 0 || squareSize <= 0 || sampleCount == 0
        || sampleCount % std::size_t(width) != 0) return false;
    const auto height = sampleCount / std::size_t(width);
    if (height == 0) return false;
    // The upper edge is exclusive. Keep even fractional positions in the
    // final cell unchanged, rather than trimming a one-elmo border.
    const float maximumX = std::nextafter(float(width) * squareSize, 0.f);
    const float maximumZ = std::nextafter(float(height) * squareSize, 0.f);
    positionX = std::clamp(positionX, 0.f, maximumX);
    positionZ = std::clamp(positionZ, 0.f, maximumZ);
    return true;
}
}
#endif
