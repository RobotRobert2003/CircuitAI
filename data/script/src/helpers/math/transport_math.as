// Pure logistics policy; caller owns persistence, engine state and units.
namespace TransportMath {
    int DesiredCount(float sustainedMetalIncome, float minimumIncome,
        float additionalCarrierIncomeStart, float metalIncomePerAdditionalCarrier,
        int previousTarget) {
        if (sustainedMetalIncome < minimumIncome) return previousTarget;
        int target = 1;
        if (metalIncomePerAdditionalCarrier > 0.0f && sustainedMetalIncome > additionalCarrierIncomeStart)
            target += int((sustainedMetalIncome - additionalCarrierIncomeStart) / metalIncomePerAdditionalCarrier);
        return target > previousTarget ? target : previousTarget;
    }
    bool Arrived(float squaredDistance, float arrivalRadius, bool isLoaded) {
        return !isLoaded && arrivalRadius > 0.0f && squaredDistance <= arrivalRadius * arrivalRadius;
    }
}
