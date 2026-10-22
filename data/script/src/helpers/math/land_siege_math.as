namespace LandSiegeMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const int Zero = 0;
    const int One = 1;

    // Pure policy: no clock, callbacks or allocation. Income drives the
    // mid/late-game ramp; elapsed time alone must not bankrupt a weak economy.
    float Budget(float income, float minimumIncome, float fullIncome,
        float staticMetal, float armyMetal, float responseRatio,
        float earlyShare, float lateShare, float teamFactor)
    {
        if (income < minimumIncome || staticMetal <= Zero || armyMetal <= Zero
            || teamFactor <= Zero) return Zero;
        float ramp = fullIncome > minimumIncome ?
            (income - minimumIncome) / (fullIncome - minimumIncome) : One;
        if (ramp < Zero) ramp = Zero;
        if (ramp > One) ramp = One;
        const float threatBudget = staticMetal * responseRatio / teamFactor;
        const float armyBudget = armyMetal * (earlyShare + (lateShare - earlyShare) * ramp);
        return threatBudget < armyBudget ? threatBudget : armyBudget;
    }
    bool CanAdd(float budget, float committed, float cost)
    {
        // No rounding-up exception: a single expensive siege unit may not
        // consume the screen's budget, even if none has been built yet.
        return cost > Zero && committed + cost <= budget;
    }
}
