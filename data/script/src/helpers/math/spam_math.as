// Pure policy, no engine calls. D-216; tested at activation/release boundaries.
namespace SpamMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float UnitValue = 1.0f;
    const float ZeroValue = 0.0f;
    const int Zero = 0;
    const int One = 1;

    bool Funded(float metal, float energy, bool energyEmpty, bool metalFull,
        float bank, float minimumMetalIncome, float minimumEnergyIncome, float floatingMetalIncome, float minimumMetalBank,
        bool active, float release)
    {
        if (energyEmpty) return false;
        const float fraction = active ? release : UnitValue;
        return energy >= minimumEnergyIncome * fraction
            && (metal >= minimumMetalIncome * fraction || (metalFull && bank >= minimumMetalBank && metal >= floatingMetalIncome));
    }
    int Labs(float metal, float minimum, float step, int maximumCount)
    {
        if (metal < minimum || step <= ZeroValue || maximumCount <= Zero) return Zero;
        const int unitCount = One + int((metal - minimum) / step);
        return unitCount < maximumCount ? unitCount : maximumCount;
    }
}
