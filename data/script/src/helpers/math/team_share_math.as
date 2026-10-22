// D-175: allocation arithmetic; the caller owns settings, snapshots and sends.
namespace TeamShareMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;

    float Budget(float current, float storage, float threshold, float fraction, bool ready)
    {
        if (!ready || storage <= ZeroValue || current <= ZeroValue || current < threshold * storage) return ZeroValue;
        const float amount = fraction * storage;
        if (amount <= ZeroValue) return ZeroValue;
        return amount < current ? amount : current;
    }

    float Amount(float freeStorage, float budget, float minimum)
    {
        const float amount = freeStorage < budget ? freeStorage : budget;
        return amount > ZeroValue && amount >= minimum ? amount : ZeroValue;
    }
}
