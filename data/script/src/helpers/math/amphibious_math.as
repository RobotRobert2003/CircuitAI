// Pure wave policy, shared by the runtime controller and standalone tests.
namespace AmphibiousMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const int Zero = 0;
    const int FormationSideCount = 2;
    const int One = 1;
    const float ZeroValue = 0.0f;
    const float EconomyRaidScoreMultiplier = 4.0f;
    const float UnitValue = 1.0f;
    const float TargetDistanceScale = 800.0f;
    const float NearbyNavalDistance = 1000.0f;
    const float NearbyNavalScoreMultiplier = 2.0f;
    const float BeachTravelDistanceScale = 2400.0f;

    int FormationLane(int index) {
        if (index<=Zero) return Zero;
        return index%FormationSideCount==One ? (index+One)/FormationSideCount : -index/FormationSideCount;
    }
    bool Scope(bool technologyRole, bool airRole, bool experimental) { return experimental && (technologyRole || airRole); }
    // TECH reserves Telchine recruitment for starts whose land army cannot leave.
    // AIR's auxiliary production and already-owned amphibious combat are separate.
    bool TelchineStartAllowed(bool technologyRole, bool landLocked) { return !technologyRole || landLocked; }
    bool Gathered(int alive, int arrived, float fraction) {
        return alive > Zero && arrived > Zero && float(arrived) >= float(alive) * fraction;
    }
    bool Release(int alive, int arrived, int target, int minimum, int age, int timeout, float fraction) {
        return alive >= minimum && (alive >= target || age >= timeout) && Gathered(alive, arrived, fraction);
    }
    bool Secured(int alive, int arrived, float fraction, bool contact, int quietFrames, int requiredFrames) {
        return !contact && quietFrames >= requiredFrames && Gathered(alive, arrived, fraction);
    }
    bool Landing(bool crossedWater, float height) { return crossedWater && height >= ZeroValue; }
    bool MayAdvance(bool assembling, bool secured) { return assembling || secured; }
    float TargetScore(bool raider, bool economy, float cost, float distance, float threat) {
        return (raider && economy ? EconomyRaidScoreMultiplier : UnitValue) * cost / (UnitValue + distance / TargetDistanceScale + threat);
    }
    bool RecruitReady(float minimumIncome, float gate, int stableFrames, int windowFrames,
        float metalBank, float metalCost, float metalReserve, float energyBank, float energyBuffer, bool energyStalling) {
        return minimumIncome >= gate && stableFrames >= windowFrames && metalCost > ZeroValue
            && metalBank >= metalCost + metalReserve && energyBank >= energyBuffer && !energyStalling;
    }
    float RecruitSeconds(float metalCost, float energyCost, float metalIncome, float energyIncome, float metalShare, float energyShare) {
        if (metalCost <= Zero || energyCost < Zero || metalIncome <= Zero || energyIncome <= Zero || metalShare <= Zero || energyShare <= Zero) return -UnitValue;
        const float metalSeconds = metalCost / (metalIncome * metalShare), energySeconds = energyCost / (energyIncome * energyShare);
        return metalSeconds > energySeconds ? metalSeconds : energySeconds;
    }
    int GuardAllocation(int alive, int desired, int assaultMinimum, int groups, int maximum) {
        if (groups >= maximum || alive < desired + assaultMinimum || desired <= Zero || assaultMinimum <= Zero) return Zero;
        return desired;
    }
    float BeachScore(float assets, float navalDistance, float travel, float threat) {
        if (assets <= Zero || threat < Zero) return ZeroValue;
        const float naval = navalDistance < NearbyNavalDistance ? NearbyNavalScoreMultiplier : UnitValue;
        return naval * assets / (UnitValue + travel / BeachTravelDistanceScale + threat);
    }
    bool GuardRelease(bool assets, int absentFrames, int graceFrames, bool claimLost) {
        return claimLost || (!assets && absentFrames >= graceFrames);
    }
    bool ClaimPrecedes(int team, int serial, int ownTeam, int ownSerial) {
        return team < ownTeam || (team == ownTeam && serial < ownSerial);
    }
}
