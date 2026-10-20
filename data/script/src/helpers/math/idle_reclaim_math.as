// Pure idle-reclaim rules: no engine callbacks, scans or unit orders.
namespace IdleReclaimMath {
    // Grid cell that merges nearby deaths into one wreck site. Map axes stay
    // well under 4096 cells for any cell size >= 16 elmos.
    int CellKey(float x, float z, float cell) {
        const float size = cell > 1.0f ? cell : 1.0f;
        return int(x / size) * 4096 + int(z / size);
    }
    // Metal a lost unit leaves on the ground (BAR wrecks hold part of the cost).
    float WreckMetal(float costM, float fraction) {
        if (costM <= 0.0f || fraction <= 0.0f) return 0.0f;
        return costM * fraction;
    }
    // Value per distance: a rich far site can beat a poor near one.
    float Score(float metal, float distance, float bias) {
        if (metal <= 0.0f) return 0.0f;
        return metal / ((distance > 0.0f ? distance : 0.0f) + (bias > 1.0f ? bias : 1.0f));
    }
    // A site nobody has added to for `lifetime` frames is assumed taken.
    bool Expired(int frame, int lastAdded, int lifetime) {
        return lifetime > 0 && frame - lastAdded >= lifetime;
    }
    // "Idle" for a constructor: patrol, wait, nothing at all, or a guard on a
    // static unit (assisting a factory). A guard on a mobile constructor is
    // build assistance and stays.
    bool IdleWork(bool hasTask, bool isPatrol, bool isWait, bool isGuard, bool guardMobile) {
        if (!hasTask) return true;
        if (isPatrol || isWait) return true;
        return isGuard && !guardMobile;
    }
    // Every sampled surface threat at or under the limit.
    bool AllSafe(const array<float>@ threats, float limit) {
        for (uint i = 0; i < threats.length(); ++i)
            if (threats[i] > limit) return false;
        return true;
    }
}
