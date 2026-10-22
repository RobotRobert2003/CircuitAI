// D-296: pure scout-raid policy arithmetic. No engine calls; tested by
// tests/scout_raid_math_tests.as through the standalone AngelScript runner.
namespace ScoutRaidMath {
    const float ZeroValue = 0.0f;
    const float UnitValue = 1.0f;
    const float CostScale = 100.0f;      // metal per unit of value bonus
    const float DistanceScale = 1000.0f; // elmos per halving of the distance discount
    const float RearScale = 2000.0f;     // elmos over which enemy-start proximity decays
    const float FrontScale = 3000.0f;    // elmos behind the combat front that saturate depth

    // Target value: kind weight, cost bonus, backline depth, nearer first.
    // A non-positive weight disables the kind (returns 0).
    float Score(float kindWeight, float cost, float rear, float distance)
    {
        if (!(kindWeight > ZeroValue)) return ZeroValue;
        const float c = cost > ZeroValue ? cost : ZeroValue;
        const float d = distance > ZeroValue ? distance : ZeroValue;
        const float r = rear > ZeroValue ? rear : ZeroValue;
        return kindWeight * (UnitValue + c / CostScale) * r / (UnitValue + d / DistanceScale);
    }

    // Backline depth in [1, 3]: +1 near an enemy start, +1 far behind the
    // combat front. A negative distance means "unknown" and adds nothing.
    float Rear(float toEnemyStart, float fromFront)
    {
        float rear = UnitValue;
        if (toEnemyStart >= ZeroValue) rear += UnitValue / (UnitValue + toEnemyStart / RearScale);
        if (fromFront >= ZeroValue) rear += fromFront >= FrontScale ? UnitValue : fromFront / FrontScale;
        return rear;
    }

    // Waypoint compaction: keep a route point when the heading changes or
    // when the distance since the last kept point reaches the spacing. Grid
    // routes are 64-elmo steps; this bounds MOVE commands per replan.
    bool Keep(float previousDx, float previousDz, float dx, float dz, float sinceKept, float spacing)
    {
        if (sinceKept >= spacing) return true;
        const float cross = previousDx * dz - previousDz * dx;
        const float dot = previousDx * dx + previousDz * dz;
        return cross > 1.0f || cross < -1.0f || dot <= ZeroValue;
    }

    // INV-212: hazard on the route ahead must be answered by a queued replan
    // within cooldown + grace. Returns true when that promise is broken.
    bool HazardOverdue(int since, int now, int cooldownFrames, int graceFrames, bool queued)
    {
        if (since < 0 || queued) return false;
        return now - since > cooldownFrames + graceFrames;
    }
}
