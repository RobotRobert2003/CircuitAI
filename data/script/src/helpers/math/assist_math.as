// Pure mobile-assistance admission. All policy thresholds come from the role.
namespace AssistMath {
    int TargetCount(float income, float minimumIncome, float incomePerWorker, int maximum) {
        if (!(income >= minimumIncome) || !(incomePerWorker > 0.0f) || maximum <= 0) return 0;
        // Clamp before the integer conversion, including extreme economy settings.
        const float target = income / incomePerWorker;
        return target >= float(maximum) ? maximum : int(target);
    }
    bool CanRecruit(int owned, int pending, int target, bool combatReady,
        bool metalSurplus, bool bankPressure, bool energyStalling) {
        return owned >= 0 && pending == 0 && owned < target && combatReady
            && (metalSurplus || bankPressure) && !energyStalling;
    }
}
