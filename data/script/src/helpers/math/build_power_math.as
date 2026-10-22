// Resource amounts are engine units; time is simulation seconds. No role state.
namespace BuildPowerMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;
    const float MaximumValidScalarValue = 1.0e12f;
    const float UnconstrainedResourcePower = 1.0e10f;
    const int Zero = 0;
    const float UnitValue = 1.0f;
    const int One = 1;
    const int RequiredRefillCount = 2;

    // Conversion expenditure is already in usage. Remove it once, then charge
    // all installed/framed/queued converter capacity, including switched-off
    // converters. Storage percentage alone cannot represent sustained supply.
    float ConversionHeadroom(float energyIncome, float energyUsage,
        float conversionUsage, float conversionCapacity, float energyReserve) {
        return energyIncome - Max(ZeroValue, energyUsage - conversionUsage)
            - conversionCapacity - energyReserve;
    }

    bool Valid(float value) { return value >= ZeroValue && value < MaximumValidScalarValue; }
    float Max(float firstValue, float secondValue) { return firstValue > secondValue ? firstValue : secondValue; }
    float Min(float firstValue, float secondValue) { return firstValue < secondValue ? firstValue : secondValue; }

    // Cost is paid during construction, then the new worker starts its job.
    // Piecewise-linear balance needs testing at both breakpoints, not just end.
    bool Funded(float bank, float reserve, float income, float usage, float committed,
        float cost, float finishSeconds, float additionalUsage, float horizon)
    {
        if (!Valid(bank) || !Valid(reserve) || !Valid(income) || !Valid(usage)
            || !Valid(committed) || !Valid(cost) || !Valid(finishSeconds) || finishSeconds <= ZeroValue
            || !Valid(additionalUsage) || !Valid(horizon) || horizon <= ZeroValue) return false;
        const float start = bank - reserve - committed;
        if (start < ZeroValue) return false;
        const float finish = Min(finishSeconds, horizon);
        const float paid = cost * finish / finishSeconds;
        const float atFinish = start + (income - usage) * finish - paid;
        const float atEnd = atFinish + (income - usage - additionalUsage) * (horizon - finish);
        // If completion lies outside the horizon, reserve the rest of the order.
        return atFinish >= ZeroValue && atEnd >= Max(ZeroValue, cost - paid);
    }
    float Room(float bank, float reserve, float income, float usage, float committed, float horizon)
    {
        if (!Valid(bank) || !Valid(reserve) || !Valid(income) || !Valid(usage)
            || !Valid(committed) || !Valid(horizon) || horizon <= ZeroValue) return ZeroValue;
        return Max(ZeroValue, income - usage + Max(ZeroValue, bank - reserve - committed) / horizon);
    }
    float Power(float metalRate, float energyRate, float work, float metalCost, float energyCost)
    {
        if (!Valid(metalRate) || !Valid(energyRate) || !Valid(work) || work <= ZeroValue
            || !Valid(metalCost) || !Valid(energyCost) || (metalCost <= ZeroValue && energyCost <= ZeroValue)) return ZeroValue;
        const float powerFromMetal = metalCost > ZeroValue ? metalRate * work / metalCost : UnconstrainedResourcePower;
        const float powerFromEnergy = energyCost > ZeroValue ? energyRate * work / energyCost : UnconstrainedResourcePower;
        return Min(powerFromMetal, powerFromEnergy);
    }
    bool Pressure(float bank, float storage, float oldest, int samples, int window,
        int fullSamples, float high, float rise)
    {
        if (!Valid(bank) || !Valid(storage) || storage <= ZeroValue || !Valid(oldest)
            || window <= Zero || !Valid(high) || !Valid(rise)) return false;
        return (samples >= window && bank >= oldest + rise)
            || (fullSamples >= window && bank >= storage * high);
    }
    int Batch(float availablePower, float work, float seconds, int pending, int safety)
    {
        if (!Valid(availablePower) || !Valid(work) || work <= ZeroValue || !Valid(seconds)
            || seconds <= ZeroValue || pending < Zero || safety <= Zero) return Zero;
        const int capacity = int(Min(float(safety), Max(UnitValue, availablePower * seconds / work)));
        return capacity > pending ? capacity - pending : Zero;
    }
    bool Refilling(const array<float>& in banks, float storage, float low, float high) {
        if (!Valid(storage) || storage <= Zero || low < Zero || high <= low || high > One) return false;
        bool dipped = false;
        int refills = Zero;
        for (uint index = Zero; index < banks.length(); ++index) {
            if (banks[index] <= storage * low) dipped = true;
            if (dipped && banks[index] >= storage * high) { ++refills; dipped = false; }
        }
        return refills >= RequiredRefillCount;
    }
    float Shortage(float wanted, float available, float arriving)
    {
        if (!Valid(wanted) || !Valid(available) || !Valid(arriving)) return ZeroValue;
        return Max(ZeroValue, wanted - available - arriving);
    }
    float ProjectShortage(float working, float extra, float remaining, float minimumSeconds,
        float assigned, float queued)
    {
        if (!Valid(working) || !Valid(extra) || !Valid(remaining) || !Valid(minimumSeconds)
            || minimumSeconds <= Zero || !Valid(assigned) || !Valid(queued)) return Zero;
        // Assigned includes travellers and workers temporarily limited by energy.
        // They can consume the newly available budget before we buy more power.
        return Max(ZeroValue, Min(working + extra, remaining / minimumSeconds) - assigned - queued);
    }
}
