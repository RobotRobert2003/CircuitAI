// Pure economy decisions shared by TECH policy and its actual-VM tests.
namespace TechEconomyMath {
    int FastAssistTarget(float metalIncome, float incomeScale, bool rushActive, int maximum) {
        const float income = metalIncome * incomeScale;
        int wanted = income < 100.0f ? 5 * int(income / 45.0f) : 5 * int(income / 20.0f);
        // D-070's opening budget precedes D-119's absolute workforce ceiling.
        if (rushActive && wanted > 2) wanted = 2;
        if (wanted > maximum) wanted = maximum;
        return wanted;
    }
}

namespace EcoPlanner {
    // A low-income exception can restore funded lost capacity, never expand it.
    bool ReplacementFunded(int losses, int pending, float bank, float cost) {
        return losses > pending && cost > 0.0f && bank >= cost * float(pending + 1);
    }
    enum ConversionReason { READY, PENDING, CAPACITY, METAL_FULL, UNAVAILABLE, UNBUILDABLE, INCOME, PLACEMENT, NO_OPTION }
    ConversionReason DecideConversion(bool metalFull, bool defined, int pending, int parallel,
        bool supplied, bool available, bool buildable, bool income, bool placementRejected) {
        if (metalFull) return METAL_FULL;
        if (!defined) return UNAVAILABLE;
        if (pending > 0 && pending >= parallel) return PENDING;
        if (parallel <= 0) return UNAVAILABLE;
        if (!supplied) return pending > 0 ? PENDING : CAPACITY;
        if (!available) return pending > 0 ? PENDING : UNAVAILABLE;
        if (!buildable) return pending > 0 ? PENDING : UNBUILDABLE;
        if (!income) return pending > 0 ? PENDING : INCOME;
        if (placementRejected) return pending > 0 ? PENDING : PLACEMENT;
        return READY;
    }
}
