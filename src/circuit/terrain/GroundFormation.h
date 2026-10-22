#ifndef CIRCUIT_GROUND_FORMATION_H
#define CIRCUIT_GROUND_FORMATION_H
#include <algorithm>

namespace circuit::formation {
inline constexpr float RetentionRadiusMultiplier = 1.5f;
// A rear firing band must fit inside the rear weapon's usable reach. If it
// cannot fit, retain physical separation and let the caller stage rather than
// silently place fragile units in front. Terrain/trajectory are checked later.
inline float Separation(float frontRange, float rearRange, float minimum, float maximum) {
    return std::clamp(rearRange-frontRange, minimum, maximum);
}
inline float RearRadius(float frontRadius, float frontRange, float rearRange,
                        float minimum, float maximum) {
    return frontRadius+Separation(frontRange,rearRange,minimum,maximum);
}
inline bool Compatible(bool sameFamily, bool sameArea, bool frontAlive,
                       float distanceSquared, float radius, bool alreadyPaired) {
    const float retention = alreadyPaired ? RetentionRadiusMultiplier : 1.f;
    return sameFamily && sameArea && frontAlive
        && distanceSquared <= radius*radius*retention*retention;
}
}
#endif
