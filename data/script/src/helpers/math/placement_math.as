// Pure placement geometry, shared by policy and the standalone AS tests.
namespace PlacementMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;

    bool FriendlyTerritory(float allyDistanceSquared, float enemyDistanceSquared)
    {
        return allyDistanceSquared >= ZeroValue && enemyDistanceSquared >= ZeroValue
            && allyDistanceSquared < enemyDistanceSquared;
    }
    bool CoversCore(float coverage, float distanceSquared, float coreRadius)
    {
        return coverage > ZeroValue && coreRadius >= ZeroValue && coverage >= coreRadius
            && distanceSquared >= ZeroValue && distanceSquared <= (coverage - coreRadius) * (coverage - coreRadius);
    }
    bool FootprintIntersectsCircle(float positionX, float positionZ, float halfWidth, float halfDepth,
        float centreX, float centreZ, float radius)
    {
        if (halfWidth < ZeroValue || halfDepth < ZeroValue || radius < ZeroValue) return true;
        float distanceX = positionX - centreX;
        float distanceZ = positionZ - centreZ;
        if (distanceX < ZeroValue) distanceX = -distanceX;
        if (distanceZ < ZeroValue) distanceZ = -distanceZ;
        distanceX = distanceX > halfWidth ? distanceX - halfWidth : ZeroValue;
        distanceZ = distanceZ > halfDepth ? distanceZ - halfDepth : ZeroValue;
        return distanceX * distanceX + distanceZ * distanceZ <= radius * radius;
    }
}
