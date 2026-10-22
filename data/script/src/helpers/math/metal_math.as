// Pure metal-field investment arithmetic; inputs are runtime costs/income.
namespace MetalMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;
    const float UnitValue = 1.0f;
    const int Zero = 0;
    const float ExtractorStorageCeilingFraction = .75f;
    const float ExtractorEnergyReserve = 30.0f;
    const float ExtractorGrowthMultiplier = 1.25f;
    const float LowMetalStorageFraction = .2f;
    const float ExtractorDemandMargin = 1.05f;
    const float InvestmentIncomeShare = .35f;
    const float InvestmentStorageFullFraction = .9f;

    float Positive(float value) { return value > ZeroValue ? value : ZeroValue; }
    float Sustainable(float metal, float energy, float otherEnergy, float ratio) {
        if (ratio <= ZeroValue) return ZeroValue;
        const float funded = Positive(energy - otherEnergy) / ratio;
        return metal < funded ? Positive(metal) : funded;
    }
    float EnergyGoal(float desiredMetal, float ratio, float upkeep, float pull, float margin) {
        const float desired = Positive(desiredMetal) * Positive(ratio) + Positive(upkeep);
        const float busy = Positive(pull) * (UnitValue + Positive(margin));
        return desired > busy ? desired : busy;
    }
    bool OpeningDone(int claimed, int budget, int seconds, int deadline) {
        return claimed >= budget || seconds >= deadline;
    }
    bool NeedMex(float metal, float energy, float ratio, float bank, float storage, float pull) {
        if (ratio <= Zero || storage <= Zero || bank >= storage * ExtractorStorageCeilingFraction) return false;
        return metal < Positive(energy - ExtractorEnergyReserve) / ratio * ExtractorGrowthMultiplier
            || (bank < storage * LowMetalStorageFraction && pull > metal * ExtractorDemandMargin);
    }
    bool CanInvest(float metal, float energy, float metalBank, float energyBank, float metalCost, float energyCost, float horizon) {
        return horizon > Zero && metalCost > Zero && energyCost >= Zero
            && metalBank + Positive(metal) * horizon * InvestmentIncomeShare >= metalCost
            && energyBank + Positive(energy) * horizon * InvestmentIncomeShare >= energyCost;
    }
    bool NeedInvestmentStorage(float bank, float storage, float nextCost) {
        return storage > Zero && nextCost > storage && bank >= storage * InvestmentStorageFullFraction;
    }
    bool RetirePower(float income, float removed, float committedPull, float target, float reserve) {
        const float need = committedPull > target ? committedPull : target;
        return removed > Zero && income - removed >= need * (UnitValue + Positive(reserve));
    }
}
