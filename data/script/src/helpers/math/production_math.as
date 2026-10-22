// Pure, role-neutral arithmetic. No engine calls, settings or mutable state.
namespace ProductionMath {
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const float ZeroValue = 0.0f;
    const int Zero = 0;
    const float UnitValue = 1.0f;
    const float FloatingStorageFraction = 0.75f;
    const float MinimumFloatingMetal = 300.0f;
    const int One = 1;
    const float DefaultReachMargin = 16.0f;
    const int ClusterColumnCount = 3;
    const float ClusterRowCenter = 0.5f;
    const float ClusterWidthSquaredFactor = 9.0f;
    const float ClusterDepthSquaredFactor = 4.0f;
    const float MaximumValidScalarValue = 1.0e12f;
    const int TurretsPerBank = 10;
    const int TurretsPerRow = 5;
    const float TurretHalfWidth = 0.5f;
    const int TurretRowCenterIndex = 2;

    // Shared TECH/AIR threshold; callers require a completed reactor and no stall.
    bool LowTierEnergyReclaim(bool completedAdvancedFusions, float income, float retiringOutput, float pull, float margin)
    {
        return completedAdvancedFusions || income - retiringOutput >= pull * margin;
    }

    bool ConstructorTurn(int consecutive, int maximum)
    {
        return consecutive >= Zero && maximum > Zero && consecutive < maximum;
    }

    bool AssistUseful(float assigned, float work, float progress, float seconds)
    {
        if (!Valid(assigned) || !Valid(work) || !Valid(progress) || progress >= UnitValue
            || !Valid(seconds) || seconds <= ZeroValue) return false;
        return assigned < work * (UnitValue - progress) / seconds;
    }
    bool ExpansionSupportReady(int factories, int finishedFactories, int leastSupport, int required)
    {
        if (factories < Zero || finishedFactories < Zero || leastSupport < Zero || required <= Zero) return false;
        return factories == finishedFactories && (factories == Zero || leastSupport >= required);
    }
    bool MetalFloating(float bank, float storage)
    {
        return Valid(bank) && Valid(storage) && storage > ZeroValue
            && bank >= (storage * FloatingStorageFraction > MinimumFloatingMetal ? storage * FloatingStorageFraction : MinimumFloatingMetal);
    }

    bool LabIncomeReady(float minimum, bool fullWindow, float threshold, float bank, float cost)
    {
        if (!Valid(minimum) || !Valid(threshold) || !Valid(bank) || !Valid(cost) || cost <= ZeroValue || threshold <= ZeroValue) return false;
        return bank >= cost || (fullWindow && minimum >= threshold);
    }
    int StrikeTarget(float income, float perUnit, int floor, int maximumCount)
    {
        if (!Valid(income) || !Valid(perUnit) || perUnit <= ZeroValue || floor < Zero || maximumCount < floor) return Zero;
        const int value = int(income / perUnit);
        return value < floor ? floor : value > maximumCount ? maximumCount : value;
    }
    // Conversion capacity follows surplus, not a fixed metal-income ceiling.
    int ConverterTarget(float income, float aircraft, float reserve, float draw)
    {
        if (!Valid(income) || !Valid(aircraft) || !Valid(reserve) || !Valid(draw)
            || draw <= ZeroValue || income <= aircraft + reserve) return Zero;
        const float value = (income - aircraft - reserve) / draw;
        const int whole = int(value);
        return whole + (value > float(whole) ? One : Zero);
    }
    bool ConverterMayQueue(int target, int planned, int queued, int parallel)
    {
        return planned >= Zero && target > planned && queued >= Zero && queued < parallel;
    }

    float Progress(int count, int first, int full)
    {
        if (count <= first || first < Zero || full <= first) return ZeroValue;
        return count >= full ? UnitValue : float(count - first) / float(full - first);
    }
    float BoundedBlend(float first, float last, float progress)
    {
        if (!Valid(first) || !Valid(last) || !Valid(progress)) return ZeroValue;
        return first + (last - first) * (progress > UnitValue ? UnitValue : progress);
    }
    bool WithinReach(float distanceSquared, float reach, float margin = DefaultReachMargin)
    {
        return Valid(distanceSquared) && Valid(reach) && Valid(margin) && reach >= margin
            && distanceSquared <= (reach - margin) * (reach - margin);
    }
    // Projected counts suppress duplicate orders; only completed units release an assistant.
    bool CrewReady(int completed, int target) { return target > Zero && completed >= target; }
    bool FactoryAssistUseful(bool crewReady, bool factoryFinished, bool recruiting)
    {
        return !crewReady || !factoryFinished || recruiting;
    }
    int DefenceRecruitTarget(int target, int otherDefenders, int committedElsewhere)
    {
        if (target < Zero || otherDefenders < Zero || committedElsewhere < Zero) return Zero;
        return (target > otherDefenders ? target - otherDefenders : Zero) + committedElsewhere;
    }

    float ClusterAcross(int slot, float width) { return float(slot % ClusterColumnCount - One) * width; }
    float ClusterAlong(int slot, float depth) { return (float(slot / ClusterColumnCount) - ClusterRowCenter) * depth; }
    float ClusterDiameterSquared(float width, float depth) { return ClusterWidthSquaredFactor * width * width + ClusterDepthSquaredFactor * depth * depth; }
    bool MexNeedsUpgrade(float extraction, float advancedExtraction)
    {
        return Valid(extraction) && extraction > ZeroValue
            && (!Valid(advancedExtraction) || advancedExtraction <= ZeroValue || extraction < advancedExtraction);
    }
    bool ReactorMayStart(int basicMetalExtractors, int unfinishedMetalExtractors, int queuedMetalExtractors)
    {
        return basicMetalExtractors == Zero && unfinishedMetalExtractors == Zero && queuedMetalExtractors == Zero;
    }
    bool PreparationDue(int seconds, int targetSeconds, int leadSeconds)
    {
        return seconds >= Zero && targetSeconds > Zero && leadSeconds >= Zero && seconds >= targetSeconds - leadSeconds;
    }
    bool Valid(float value) { return value >= ZeroValue && value < MaximumValidScalarValue; }
    float Rate(float work, float power, float startupDelaySeconds)
    {
        if (!Valid(work) || work <= ZeroValue || !Valid(power) || power <= ZeroValue || !Valid(startupDelaySeconds)) return ZeroValue;
        return power / (work + startupDelaySeconds * power);
    }
    float FundedRate(float rate, float metalCost, float energyCost, float metal, float energy)
    {
        if (!Valid(rate) || !Valid(metal) || !Valid(energy) || !Valid(metalCost) || !Valid(energyCost)) return ZeroValue;
        if (metalCost > ZeroValue && rate * metalCost > metal) rate = metal / metalCost;
        if (energyCost > ZeroValue && rate * energyCost > energy) rate = energy / energyCost;
        return rate;
    }

    bool Funded(float bank, float income, float reserve, float committed, float cost, float seconds)
    {
        if (!Valid(bank) || !Valid(income) || !Valid(reserve) || !Valid(committed) || !Valid(cost) || !Valid(seconds)) return false;
        return bank + income * seconds >= reserve + committed + cost;
    }
    // Smallest usable support allocation; pending support is future capacity.
    int SupportTarget(float work, float factoryPower, float constructionTurretPower, float gap, float wantedRate, int maximumCount)
    {
        if (!Valid(work) || work <= ZeroValue || !Valid(factoryPower) || !Valid(constructionTurretPower) || !Valid(gap)
            || !Valid(wantedRate) || wantedRate <= ZeroValue || constructionTurretPower <= ZeroValue || maximumCount <= Zero) return Zero;
        for (int unitCount = Zero; unitCount < maximumCount; ++unitCount)
            if (Rate(work, factoryPower + float(unitCount) * constructionTurretPower, gap) >= wantedRate) return unitCount;
        return maximumCount;
    }
    // Two five-wide banks, two rows deep. No turret lies in the aircraft pad.
    float BayAcross(int slot, float factoryHalfWidth, float constructionTurretWidth, float gap)
    {
        const int bank = slot / TurretsPerBank;
        const int row = (slot % TurretsPerBank) / TurretsPerRow;
        return (bank == Zero ? -UnitValue : UnitValue) * (factoryHalfWidth + gap + constructionTurretWidth * (TurretHalfWidth + float(row)));
    }
    float BayAlong(int slot, float constructionTurretWidth) { return float((slot % TurretsPerBank) % TurretsPerRow - TurretRowCenterIndex) * constructionTurretWidth; }
    bool Inside(float positionX, float positionZ, float width, float height, float margin)
    {
        return Valid(positionX) && Valid(positionZ) && Valid(width) && Valid(height) && Valid(margin)
            && positionX < width && positionZ < height
            && positionX >= margin && positionZ >= margin && positionX <= width - margin && positionZ <= height - margin;
    }
    bool CapacityReady(int count, int ceiling, int stableFrames, int requiredFrames, float bank, float cost)
    {
        return count >= Zero && count < ceiling && stableFrames >= requiredFrames && requiredFrames >= Zero
            && Valid(bank) && Valid(cost) && bank >= cost;
    }
}
