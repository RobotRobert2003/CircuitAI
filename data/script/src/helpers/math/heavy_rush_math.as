// Pure affordability admission, once per new unit, not per-frame spending.
namespace HeavyRushMath {
    bool RequiresFusion(bool rushPending, int completedFusions, float geothermalOutput,
        float requiredStableOutput) {
        return rushPending && completedFusions == 0 && geothermalOutput < requiredStableOutput;
    }
    float AvailableEnergy(float income, float usage, float converterUsage, float reserve) {
        // Conversion is interruptible; potential build pull is not actual
        // consumption. Counting either as essential can deadlock a full bank.
        const float essential = usage > converterUsage ? usage - converterUsage : 0.0f;
        const float available = income - essential - reserve;
        return available > 0.0f ? available : 0.0f;
    }
    bool CanFund(float metalCost, float energyCost, float metalIncome, float availableEnergyIncome,
        float metalBank, float energyBank, float budgetSeconds, float incomeShare, float minimumMetalIncome) {
        if (budgetSeconds <= 0.0f || incomeShare <= 0.0f || incomeShare > 1.0f) return false;
        const bool metalReady = (metalIncome >= minimumMetalIncome
            && metalIncome * incomeShare * budgetSeconds >= metalCost) || metalBank >= metalCost;
        // Energy bank alone cannot justify a sustained production commitment.
        // It can bridge the horizon, but require positive usable generation.
        const bool energyReady = availableEnergyIncome > 0.0f
            && availableEnergyIncome * incomeShare * budgetSeconds + energyBank * incomeShare >= energyCost;
        return metalReady && energyReady;
    }
}
