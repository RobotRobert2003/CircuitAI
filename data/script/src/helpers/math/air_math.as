// Deterministic AIR decisions. No engine state; policy constants are named below.
namespace AirMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const int Zero = 0;
    const int One = 1;
    const float RadiusToDiameter = 2.0f;
    const float UnitValue = 1.0f;
    const float RadarArrivalRadiusSquaredFactor = 4.0f;
    const float TransitionStorageFullFraction = 0.85f;
    const int FullCampusFactoryCount = 6;
    const int CampusVariantCount = 3;
    const int MinimumDefensiveWaveCount = 3;
    const float ZeroValue = 0.0f;
    const float OverflowMetalReserve = 150.0f;
    const float OverflowEnergyReserve = 500.0f;
    const int MaximumIncrementableBayCount = 2147483646;
    const int MaximumSignedInteger = 2147483647;
    const int MaximumOpeningWaveCount = 300;
    const float MaximumValidScalarValue = 1.0e12f;
    const float MaximumSafeIntegerConversion = 2147483520.0f;
    const float MaximumBomberOrdersPerCycle = 9.0f;
    const int ProductionCycleLength = 10;
    const int ReducedCampusFactoryCount = 3;

    // Full waves respect assembly; the deadline must also break assembly stalls.
    bool ReconRelease(int available, int ready, int wanted, int elapsed, int maximumWait) {
        return available > Zero && ((wanted > Zero && ready >= wanted)
            || (maximumWait > Zero && elapsed >= maximumWait));
    }
    bool BaseContact(float distanceSquared, float radius) {
        return distanceSquared >= Zero && radius > Zero && distanceSquared <= radius*radius;
    }
    int DefenceDeficit(int target, int available, int frames, int pending) {
        const int missing = target-available-frames-pending;
        return missing > Zero ? missing : Zero;
    }
    int DefenceWave(float ground, float antiAirMetal, float aircraftCost, float groundRatio, float antiAirRatio, int minimum, int maximum) {
        if (minimum < One) minimum = One;
        if (maximum < minimum) maximum = minimum;
        if (!Valid(ground) || !Valid(antiAirMetal) || !Valid(aircraftCost) || aircraftCost <= Zero
            || !Valid(groundRatio) || !Valid(antiAirRatio)) return minimum;
        const int budget = Missing(ground * groundRatio + antiAirMetal * antiAirRatio, Zero, aircraftCost);
        return budget < minimum ? minimum : budget > maximum ? maximum : budget;
    }
    bool DefenceRelease(int available, int assembled, int wanted, int age, int deadline) {
        // The first waiting aircraft owns the clock. More births or a larger
        // observed AA budget must not restart a stalled production deadline.
        return available > Zero && wanted > Zero && (assembled >= wanted || (deadline > Zero && age >= deadline));
    }
    bool DefensiveBomberTarget(bool advancedBomber, bool mobile, bool heavy) {
        return !advancedBomber || !mobile || heavy;
    }
    // Dedicated AA avoids promoting every tank whose ground weapon can shoot up.
    // Mobile AA includes advanced AA bots regardless of tier; the configurable
    // metal ceiling applies only to static AA. Disable priority without changing
    // the old score/tie order. Both helpers are allocation-free O(1) per contact.
    bool DefensiveGunshipPriority(bool enabled, bool antiAirWeapon, bool antiAirRole,
        bool mobile, float metalCost, float lightStaticMaximumMetal)
    {
        return enabled && antiAirWeapon && antiAirRole
            && (mobile || (Valid(metalCost) && Valid(lightStaticMaximumMetal)
                && lightStaticMaximumMetal > Zero && metalCost <= lightStaticMaximumMetal));
    }
    bool PreferDefensiveGunshipTarget(bool priority, float score, bool selectedPriority, float selectedScore)
    {
        // Compare tiers before scores: the incumbent bonus stabilizes targets
        // within a tier but must never shelter a tank while nearby AA free-fires.
        return priority != selectedPriority ? priority : score > selectedScore;
    }
    bool T1OpeningReady(int crew, int requiredCrew, int constructionTurrets, int requiredConstructionTurrets, bool recovering)
    {
        return !recovering && requiredCrew > Zero && requiredConstructionTurrets >= Zero
            && crew >= requiredCrew && constructionTurrets >= requiredConstructionTurrets;
    }
    float RadarSpacing(float radius, float overlap)
    {
        if (!Valid(radius) || radius <= Zero || !Valid(overlap) || overlap >= One) return Zero;
        return RadiusToDiameter * radius * (UnitValue - overlap);
    }
    bool RadarReady(bool visited, float distanceSquared, float radius)
    {
        return visited && Valid(distanceSquared) && Valid(radius) && radius > Zero && distanceSquared <= RadarArrivalRadiusSquaredFactor*radius*radius;
    }
    int RadarColumns(int count, float span, float spacing)
    {
        if (count <= Zero || !Valid(span) || !Valid(spacing) || spacing <= Zero) return Zero;
        if (span / spacing >= float(count - One)) return count;
        const int fit = One + int(span / spacing);
        return fit < count ? fit : count;
    }
    bool WorkforceTurn(bool missing, bool funded, bool emergency, int combatOrders, int maximum)
    {
        return missing && funded && maximum > Zero && (!emergency || combatOrders >= maximum);
    }
    bool SaveForLab(bool advanced, bool pending, bool recovering, bool screenReady,
        int seconds, int earliest, float metal, float energy, float minimumMetal,
        float minimumEnergy, float bank, float cost)
    {
        return !advanced && !pending && !recovering && screenReady && seconds >= earliest
            && Valid(metal) && Valid(energy) && Valid(bank) && Valid(cost) && cost > Zero
            && metal >= minimumMetal && energy >= minimumEnergy && bank < cost;
    }
    bool TransitionStorage(bool advancedPlant, float bank, float capacity, float factoryMetalCost)
    {
        return !advancedPlant && Valid(bank) && Valid(capacity) && Valid(factoryMetalCost)
            && capacity>Zero && factoryMetalCost>capacity && bank>capacity*TransitionStorageFullFraction;
    }
    // Reserve all existing obligations and the complete new order within a
    // bounded forecast, shortened for faster builders. No future gifts assumed.
    bool LabFunding(float bank, float reserve, float income, float usage,
        float committed, float cost, float work, float power, float horizon, float share)
    {
        if (!Valid(bank) || !Valid(reserve) || !Valid(income) || !Valid(usage)
            || !Valid(committed) || !Valid(cost) || !Valid(work) || !Valid(power)
            || !Valid(horizon) || !Valid(share) || cost <= Zero || work <= Zero
            || power <= Zero || horizon <= Zero || share <= Zero || share > One) return false;
        const float finish = work / power;
        const float seconds = finish < horizon ? finish : horizon;
        const float available = bank - reserve - committed;
        return available >= Zero && available + (income * share - usage) * seconds >= cost;
    }
    // Snapshot indexes can change while the same enemy is still alive.
    int RetainedContact(int current, const array<int> &in unitIdentifiers, const array<float> &in remaining)
    {
        if (current < Zero || unitIdentifiers.length() != remaining.length()) return -One;
        for (uint index=Zero;index<unitIdentifiers.length();++index)
            if (unitIdentifiers[index]==current && Valid(remaining[index]) && remaining[index]>Zero) return int(index);
        return -One;
    }
    int CampusSize(bool compact, int variant)
    {
        if (!compact || variant < Zero) return FullCampusFactoryCount;
        return variant % CampusVariantCount == Zero ? FullCampusFactoryCount : variant % CampusVariantCount == One ? ReducedCampusFactoryCount : One;
    }
    int OperationSize(int available, int required, bool openingDone, int opening,
        bool front, bool defensive, int laterMinimum)
    {
        if (available <= Zero || required < Zero || opening <= Zero || laterMinimum <= Zero) return Zero;
        int count = opening;
        if (defensive) count = required > MinimumDefensiveWaveCount ? required : MinimumDefensiveWaveCount;
        else if (front) count = available;
        else if (openingDone) count = required > laterMinimum ? required : laterMinimum;
        return count >= required && count <= available ? count : Zero;
    }
    bool SustainedProduction(bool ready, float minimumMetal, float minimumEnergy,
        float requiredMetal, float energyPerMetal, float reserveEnergy)
    {
        return ready && Valid(minimumMetal) && Valid(minimumEnergy) && Valid(requiredMetal)
            && requiredMetal > Zero && Valid(energyPerMetal) && energyPerMetal > Zero && Valid(reserveEnergy)
            && minimumMetal >= requiredMetal && minimumEnergy >= requiredMetal*energyPerMetal+reserveEnergy;
    }
    bool PendingReactor(bool reactor, bool construction, bool hasTarget, float progress)
    {
        return reactor && construction && (!hasTarget || (Valid(progress) && progress < UnitValue));
    }
    // Conservative admission for a single additional reactor after the bomber
    // milestone: leave the configured share of future income to production.
    bool OverflowGrowth(bool floatingMetal, bool recovering, bool pendingReactor, float metalBank, float energyBank,
        float metalIncome, float energyIncome, float committedMetal, float committedEnergy, float metalCost, float energyCost,
        float productionShare, float seconds)
    {
        if (!floatingMetal || recovering || pendingReactor || !Valid(metalBank) || !Valid(energyBank)
            || !Valid(metalIncome) || !Valid(energyIncome) || !Valid(committedMetal) || !Valid(committedEnergy)
            || !Valid(metalCost) || metalCost <= ZeroValue || !Valid(energyCost) || energyCost <= ZeroValue
            || !Valid(productionShare) || productionShare > UnitValue || !Valid(seconds)) return false;
        const float share = UnitValue - productionShare;
        return metalBank + metalIncome * share * seconds >= committedMetal + metalCost + OverflowMetalReserve
            && energyBank + energyIncome * share * seconds >= committedEnergy + energyCost + OverflowEnergyReserve;
    }
    bool BayAllowed(int count, int ceiling) { return count >= Zero && (ceiling <= Zero || count < ceiling); }
    int PlannedBays(int completed, int minimum) {
        if (completed < Zero) completed = Zero;
        if (completed >= MaximumIncrementableBayCount) return MaximumSignedInteger;
        return completed + One > minimum ? completed + One : minimum;
    }

    bool GrowthPhase(bool windowReady, float minimumIncome, float threshold) {
        return windowReady && Valid(minimumIncome) && threshold > ZeroValue && minimumIncome >= threshold;
    }
    bool MassBombersReady(int completedAdvancedFusions, int required) { return required <= Zero || completedAdvancedFusions >= required; }
    bool EnergyEraAllows(bool basicEnergy, bool advancedSolar, bool fusionUp, bool advancedFusionStarted) {
        if (basicEnergy) return !fusionUp && !advancedFusionStarted;
        if (advancedSolar) return !advancedFusionStarted;
        return true;
    }
    int OpeningWave(int low, int high, int roll) {
        if (low < One) low = One;
        if (high < low) high = low;
        if (high > MaximumOpeningWaveCount) high = MaximumOpeningWaveCount;
        if (low > high) low = high;
        return roll < low ? low : roll > high ? high : roll;
    }

    bool Valid(float value) { return value == value && value >= ZeroValue && value < MaximumValidScalarValue; }
    float RaidResistance(float previous, float survival, float low, float high, float growth, float recovery, float ceiling)
    {
        if (!Valid(previous) || !Valid(survival) || !Valid(ceiling) || ceiling < UnitValue) return UnitValue;
        float factor = Clamp(previous, UnitValue, ceiling);
        if (survival < low && Valid(growth) && growth > UnitValue) factor *= growth;
        else if (survival > high && Valid(recovery)) factor *= Clamp(recovery, ZeroValue, UnitValue);
        return Clamp(factor, UnitValue, ceiling);
    }
    float Clamp(float value, float lowerBound, float upperBound) { return value < lowerBound ? lowerBound : value > upperBound ? upperBound : value; }
    int Missing(float required, float available, float unitCost)
    {
        if (!Valid(required) || !Valid(available) || !Valid(unitCost) || unitCost <= ZeroValue) return Zero;
        const float need = (required - available) / unitCost;
        if (need <= ZeroValue) return Zero;
        if (need >= MaximumSafeIntegerConversion) return MaximumSignedInteger;
        const int whole = int(need);
        return whole + (float(whole) < need ? One : Zero);
    }
    bool Emergency(float armedIntrusion, float homeValue, float ratio)
    {
        return Valid(armedIntrusion) && armedIntrusion > ZeroValue && Valid(homeValue)
            && Valid(ratio) && armedIntrusion * ratio > homeValue;
    }
    // Order allocation, not a claim that unequal aircraft have equal costs.
    int BomberOrders(float homeValue, float enemyValue, int clearOrders, int parityOrders)
    {
        if (!Valid(homeValue) || !Valid(enemyValue) || homeValue <= ZeroValue) return Zero;
        if (enemyValue > homeValue) return Zero;
        const float ratio = Clamp(enemyValue / homeValue, ZeroValue, UnitValue);
        return int(Clamp(float(clearOrders) + float(parityOrders - clearOrders) * ratio, ZeroValue, MaximumBomberOrdersPerCycle));
    }
    bool BomberTurn(int sequence, int orders)
    {
        if (sequence < Zero || orders <= Zero || orders > ProductionCycleLength) return false;
        const int slot = sequence % ProductionCycleLength;
        return ((slot + One) * orders / ProductionCycleLength) > (slot * orders / ProductionCycleLength);
    }
    int WaveTarget(int wave, int first, int increment, int maximumCount, int held,
        float seconds, float rawRate, float metal, float energy, float metalCost, float energyCost)
    {
        if (wave < Zero || first <= Zero || increment < Zero || maximumCount < first || held < Zero || !Valid(seconds)
            || !Valid(rawRate) || !Valid(metal) || !Valid(energy) || !Valid(metalCost) || metalCost <= ZeroValue
            || !Valid(energyCost) || energyCost <= ZeroValue) return first > Zero ? first : One;
        float rate = rawRate;
        if (rate > metal / metalCost) rate = metal / metalCost;
        if (rate > energy / energyCost) rate = energy / energyCost;
        // Bound the float result before conversion; extreme valid configuration
        // must not overflow the schedule or a rate-times-duration integer cast.
        const float scheduled = float(first) + float(wave) * float(increment);
        const float reachable = float(held) + rate * seconds;
        const float target = scheduled < reachable ? scheduled : reachable;
        if (target <= float(first)) return first;
        if (target >= float(maximumCount)) return maximumCount;
        return int(target);
    }

    float NavalDeficit(float enemy, float friendly, float submerged, float antiSubmarineMetal) {
        if (!Valid(enemy) || !Valid(friendly) || !Valid(submerged) || !Valid(antiSubmarineMetal)) return Zero;
        const float surfaceGap = enemy > friendly ? enemy-friendly : Zero;
        const float submarineGap = submerged > antiSubmarineMetal ? submerged-antiSubmarineMetal : Zero;
        return surfaceGap > submarineGap ? surfaceGap : submarineGap;
    }
    bool NavalSectorContains(float distanceSquared,float radius) {
        return Valid(distanceSquared) && Valid(radius) && radius>Zero && distanceSquared<=radius*radius;
    }
    int NavalWave(float deficit, float minimumDeficit, float reserve, float cost, int low, int high) {
        if (!Valid(deficit) || !Valid(minimumDeficit) || deficit <= Zero || deficit < minimumDeficit
            || !Valid(reserve) || reserve < One || !Valid(cost) || cost <= Zero || low <= Zero || high < low) return Zero;
        const int raw = Missing(deficit*reserve,Zero,cost);
        return raw < low ? low : raw > high ? high : raw;
    }
    bool NavalRelease(int ready, int target, int age, int deadline, bool routeReady) {
        return routeReady && ready > Zero && target > Zero && (ready >= target || (deadline > Zero && age >= deadline));
    }
}
