namespace GeothermalMath {
    // Streaming admission, not payback: no future generator or reclaim income.
    bool Affordable(float metalCost, float energyCost, float metalBank, float energyBank,
        float metalIncome, float energyIncome, float budgetSeconds, float incomeFraction) {
        if (budgetSeconds <= 0.0f || incomeFraction <= 0.0f || incomeFraction > 1.0f
            || metalIncome < 0.0f || energyIncome < 0.0f) return false;
        return metalBank + metalIncome * budgetSeconds * incomeFraction >= metalCost
            && energyBank + energyIncome * budgetSeconds * incomeFraction >= energyCost;
    }
}
