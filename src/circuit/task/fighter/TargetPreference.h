#ifndef CIRCUIT_TARGET_PREFERENCE_H
#define CIRCUIT_TARGET_PREFERENCE_H

namespace circuit::targeting {
// A preference, not an exclusion: cheap units remain legal fallback targets.
// JSON sets the threshold per UnitDef; zero exactly preserves legacy selection.
inline bool Preferred(float minimum, float cost, bool commander, bool antiAir)
{
    return minimum > 0.f && (cost >= minimum || commander || antiAir);
}

// Never turn local target value into a map-wide chase. A valuable contact can
// displace the ordinary target within firing reach or a bounded (2x) detour.
// Squared inputs keep each candidate comparison O(1), allocation/sqrt free.
inline bool WithinDetour(float preferredSq, float ordinarySq, float rangeSq)
{
    return preferredSq <= rangeSq || preferredSq <= ordinarySq * 4.f;
}
}
#endif
