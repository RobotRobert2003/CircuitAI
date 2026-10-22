// Pure first-shot budget arithmetic. Policy supplies thresholds; no callbacks.
namespace NukeMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;
    const int Zero = 0;

    // This is a dispatch radius, not a replacement for the engine's model-radius
    // build-range test. A small permitted approach avoids stranding a refund
    // just outside bare build distance; native reclaim owns the actual movement.
    bool LocalRefundWorker(float distanceSquared, float buildDistance, float maximumApproachDistance) {
        if (!(distanceSquared >= ZeroValue) || !(buildDistance > ZeroValue) || !(maximumApproachDistance >= ZeroValue)) return false;
        const float radius = buildDistance + maximumApproachDistance;
        return distanceSquared <= radius * radius;
    }
    bool RefundHasSparePower(float income, float cost, float buildTime, float assignedPower, float divertedPower) {
        if (!(income >= ZeroValue) || !(cost > ZeroValue) || !(buildTime > ZeroValue)
            || !(assignedPower > ZeroValue) || !(divertedPower > ZeroValue)) return false;
        return assignedPower - divertedPower >= income * buildTime / cost;
    }
    bool KeepFirstStockpileBudget(bool alive, int stockpiledMissiles, int currentFrame, int deadline) {
        return alive && stockpiledMissiles <= Zero && currentFrame < deadline;
    }
}
