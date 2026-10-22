// Deterministic SEA admission and handover decisions, independent of engine state.
namespace SeaMath {
    // 0 unknown, 1 contested, 2 favorable, 3 provisionally controlled.
    int ControlState(float enemy,float friendly,int quiet,int requiredQuiet,
        int surveyed,int shores,float fraction,float minimumFleet) {
        if (enemy>0) return friendly>=enemy*1.5f ? 2 : 1;
        if (friendly<minimumFleet || quiet<requiredQuiet || shores<=0
            || float(surveyed)<float(shores)*fraction) return 0;
        return 3;
    }
    float TechConversionRedirect(float bank,float reserve,float queued,float income,float usage,float cost,float horizon,float capacity) {
        if (horizon<=0 || capacity<=0) return 0;
        const float need=usage-income+(cost+reserve+queued-bank)/horizon;
        return need<=0 ? 0 : need<capacity ? need : capacity;
    }
    int WorkerGroup(int expansion,int energy,int conversion) {
        if (expansion<=energy && expansion<=conversion) return 0;
        return energy<=conversion ? 1 : 2;
    }
    int TechSupportCount(float buildTime,float seconds,float workerPower,float turretPower,int minimum) {
        if (seconds<=0 || turretPower<=0) return minimum;
        const float missing=buildTime/seconds-workerPower;
        int needed=missing>0 ? int(missing/turretPower) : 0;
        if (missing>float(needed)*turretPower) ++needed;
        return needed>minimum ? needed : minimum;
    }

    bool ReplacementReady(int count,float readyMetal,float enemyMetal,int minimum,float ratio) {
        return count>=minimum && readyMetal>=enemyMetal*ratio;
    }
    bool MatchesFactoryReservation(int taskReservation, int factoryReservation, int gantryReservation) {
        // An absent ID (-1) is never ownership, even if both owners are absent.
        return taskReservation>=0 && (taskReservation==factoryReservation || taskReservation==gantryReservation);
    }
    // Pure admission helpers; live projects include travelling workers and frames.
    bool SupportProjectAvailable(int projects, int maximumProjects, bool yardHasProject) {
        return maximumProjects>0 && projects<maximumProjects && !yardHasProject;
    }
    bool AmphibiousIntercept(int flags, float metalCost, float distanceSquared,
        float minimumMetalCost, float radius) {
        const int amphibiousContact=256;
        const int disallowedContact=1|128; // allied or stale: never emergency authority
        return (flags&amphibiousContact)!=0 && (flags&disallowedContact)==0
            && metalCost>=minimumMetalCost && radius>0 && distanceSquared<=radius*radius;
    }
    bool GuardableLand(int cells, int interiorCells, int minimumCells, int minimumInteriorCells) {
        return cells>=minimumCells && interiorCells>=minimumInteriorCells;
    }
    bool RetainScoutTravel(bool ownsLiveRoute, bool withinDeadline, bool safeOrigin,
        bool safeDestination, bool movementComplete) {
        return ownsLiveRoute && withinDeadline && safeOrigin && safeDestination && !movementComplete;
    }
    const int ScoutExcludedContactFlags = 1|2|16|128; // allied, submerged, unknown, stale
    bool ScoutRaidTarget(int contactFlags, bool identified, bool armed,
        float scoutRange, float enemyRange, float rangeMargin) {
        return identified && (contactFlags&ScoutExcludedContactFlags)==0
            && (!armed || scoutRange>enemyRange+rangeMargin);
    }
    bool ScoutRaidExpired(int elapsedFrames, int assemblyFrames, int maximumFrames,
        int members, int ready, int minimum, bool attacking) {
        return members<minimum || elapsedFrames>maximumFrames
            || (!attacking && ready<minimum && elapsedFrames>assemblyFrames);
    }
    const int SubmarineNoTarget = 0;
    const int SubmarineStructureTarget = 1;
    const int SubmarineFactoryTarget = 2;
    const int SubmarineShipTarget = 3;
    const int SubmarineAntiSubmarineTarget = 4;
    const int SubmarineFlagshipTarget = 5;
    int SubmarineTargetRank(bool flagship, bool stationary, bool unknownContact, bool factory, bool antiSubmarine=false) {
        if (flagship) return SubmarineFlagshipTarget;
        if (!stationary && antiSubmarine) return SubmarineAntiSubmarineTarget;
        if (!stationary || unknownContact) return SubmarineShipTarget;
        return factory ? SubmarineFactoryTarget : SubmarineStructureTarget;
    }
    // Deadline aging prevents perpetual beach revisits from starving the sea
    // interior. Callers pass frames for both age and interval. Pure O(1).
    const float UnseenSurveyBonus = 4.0f;
    float SurveyPriority(int priority, bool unseen, int age, int interval, float distance, float travelScale) {
        const float overdue=float(age)/float(interval>0 ? interval : 1);
        return float(priority)+(unseen ? UnseenSurveyBonus : overdue)-distance/(travelScale>0 ? travelScale : 1.0f);
    }
    float CompositionDeficit(int completedAndPending, float ratio) {
        return ratio>0 ? -float(completedAndPending)/ratio : -1e30f;
    }
    // Named policy/geometry constants preserve the original arithmetic and types.
    // Zero/One are integer identities; ZeroValue/UnitValue are float identities.
    const int FirstAdvancedShipyardMinimumBank = 100;
    const float UnseenShoreScore = 200000.0f;
    const float ZeroValue = 0.0f;
    const float UnseenWaterScore = 100000.0f;
    const float ScoutTravelPenalty = 2.0f;
    const int One = 1;
    const float HalfArc = .5f;
    const int MinimumClosingSpeed = 1;
    const int AvailableReservationState = 0;
    const int Zero = 0;
    const float ConversionStorageTolerance = .025f;
    const float MinimumConversionStorageFraction = .60f;
    const float MinimumConversionCapacityFraction = .75f;
    const int CapitalEnergyMinimumMetalBank = 100;
    const int CapitalEnergyMinimumEnergyBank = 500;
    const int StaticProducerContactMask = 32;
    const float StaticProducerObjectiveScore = 6000.0f;
    const int MetalExtractorContactMask = 64;
    const float MetalExtractorObjectiveScore = 3500.0f;
    const float BuilderObjectiveScore = 3000.0f;
    const int StaticContactMask = 8;
    const float StaticObjectiveScore = 1800.0f;
    const float OtherObjectiveScore = 1200.0f;
    const float UrgentObjectiveBonus = 12000.0f;
    const float RetainedObjectiveMultiplier = 1.35f;
    const float ObjectiveMetalWeight = .25f;
    const float UnitValue = 1.0f;
    const float ObjectiveDistanceScale = 1600.0f;
    const int EngagementRangeMargin = 128;
    const float SignificantHealthLossFraction = .015f;
    const float DamagedHullHealthFraction = .8f;
    const float DisadvantageThreshold = .85f;
    const int StalledPursuitSeconds = 6;
    const int MinimumPursuitProgress = 16;
    const float RetreatHealthFraction = .55f;
    const float OverwhelmingAdvantageThreshold = 1.8f;
    const float CapacityBankFraction = .2f;
    const float SafeExpansionDistanceSquaredRatio = .36f;
    const int FortificationFundingSeconds = 10;
    const int FortificationMetalReserve = 50;
    const int ExhaustedReservationState = 4;
    const int MinimumRecoveryFleetMetal = 1500;
    const int FormationSideCount = 2;
    const float AntiAirRangeSpacingFraction = .55f;
    const float ObjectiveMovementThreshold = 192.0f;
    const float WeaponApproachFraction = .88f;
    const float SightApproachFraction = .8f;
    const float AdditionalTurretDemandFraction = .5f;

    float TechStartupBank(float income, float seconds, float legacyReserve, bool first) {
        if (!first) return legacyReserve;
        const float buffer=income*seconds>FirstAdvancedShipyardMinimumBank ? income*seconds : FirstAdvancedShipyardMinimumBank;
        return legacyReserve<buffer ? legacyReserve : buffer;
    }
    float ScoutScore(bool shore, bool unseen, int age, float distance) {
        // Unseen shores before open-water sweeping; travel breaks equal-age ties.
        return (shore && unseen ? UnseenShoreScore : ZeroValue)+(unseen ? UnseenWaterScore : float(age))-distance*ScoutTravelPenalty;
    }
    float AntiSubAngle(int slot,int count,float arc) {
        return count<=One ? ZeroValue : -arc*HalfArc+arc*float(slot)/float(count-One);
    }
    // Engine usage includes metal-maker consumption. Subtract that measured
    // consumption once, then subtract COMPLETE + COMMITTED capacity once.
    // Potential builder pull is not expenditure and must not suppress growth.
    float ConversionGap(float income, float usage, float converted, float capacity, float reserve) {
        const float spending=usage>converted ? usage-converted : Zero;
        const float gap=income-spending-capacity-reserve;
        return gap>Zero ? gap : Zero;
    }
    bool ConversionReady(bool metalMap, float bank, float storage, float level,
        float income, float minimum, float gap, float draw, int pending, int maximum) {
        const float threshold=level-ConversionStorageTolerance>MinimumConversionStorageFraction ? level-ConversionStorageTolerance : MinimumConversionStorageFraction;
        return !metalMap && storage>Zero && bank>=storage*threshold && income>=minimum
            && draw>Zero && gap>=draw*MinimumConversionCapacityFraction && pending<maximum;
    }
    bool CapitalEnergyReady(float metalIncome, float energyIncome, float metalBank, float energyBank,
        float metalCost, float energyCost, float horizon, float share, float minimumMetalIncome, float minimumEnergyIncome) {
        return metalCost>Zero && energyCost>Zero && horizon>Zero && share>Zero && share<=One
            && metalIncome>=minimumMetalIncome && energyIncome>=minimumEnergyIncome && metalBank>=CapitalEnergyMinimumMetalBank && energyBank>=CapitalEnergyMinimumEnergyBank
            && metalBank+metalIncome*horizon*share>=metalCost && energyBank+energyIncome*horizon*share>=energyCost;
    }
    // D-231: decisions consume observations, never issue orders. Unit tests
    // cover bait, range closure, stalled growth and local reinforcement bounds.
    float ObjectiveScore(int flags, bool builder, float cost, float distance, bool urgent, bool retained) {
        float value=(flags&StaticProducerContactMask)!=Zero ? StaticProducerObjectiveScore : (flags&MetalExtractorContactMask)!=Zero ? MetalExtractorObjectiveScore : builder ? BuilderObjectiveScore : (flags&StaticContactMask)!=Zero ? StaticObjectiveScore : OtherObjectiveScore;
        if (urgent) value+=UrgentObjectiveBonus;
        if (retained) value*=RetainedObjectiveMultiplier;
        return (value+cost*ObjectiveMetalWeight)/(UnitValue+distance/ObjectiveDistanceScale);
    }
    // D-301: the fleet fights the armed fleet in front of it before it dives
    // a distant yard (6000 vs 1200 base value otherwise sent it past the
    // enemy navy). Pure O(1); multiplier <= 1 disables.
    float EngagedObjectiveScore(float score, bool engaged, float multiplier) {
        return engaged && multiplier>One ? score*multiplier : score;
    }
    // D-301: battleships follow the cruiser core; at most one per `per`
    // cruisers after `after`, capped. Pure O(1).
    int CapitalTarget(int cruisers, int after, int per, int maximum) {
        if (cruisers<after || per<=Zero || maximum<=Zero) return Zero;
        const int wanted=One+(cruisers-after)/per;
        return wanted<maximum ? wanted : maximum;
    }
    bool Engagement(float distance, float enemyRange, float healthLoss) {
        return distance<=enemyRange+EngagementRangeMargin || healthLoss>SignificantHealthLossFraction;
    }
    bool PursuitBad(float gap, float ownSpeed, float enemySpeed, float health,
        float advantage, float seconds, float progress, float healthLoss, float maximumClosingSeconds, float outOfLeash) {
        if (outOfLeash>Zero) return true;
        // Being in range is insufficient when the local exchange is already
        // losing. Preserve damaged, outnumbered hulls even if they can fire.
        if (health<DamagedHullHealthFraction && advantage<DisadvantageThreshold && healthLoss>SignificantHealthLossFraction) return true;
        if (gap<=Zero) return false; // already able to deal damage
        if (seconds>=StalledPursuitSeconds && progress<MinimumPursuitProgress && healthLoss>SignificantHealthLossFraction) return true;
        const float closing=ownSpeed-enemySpeed;
        return health<RetreatHealthFraction || (advantage<OverwhelmingAdvantageThreshold && (closing<=MinimumClosingSpeed || gap/closing>maximumClosingSeconds));
    }
    float GrowthUsage(float usage, float redirect) { return usage>redirect ? usage-redirect : Zero; }
    float LocalWorkPower(float power, bool expansion, bool sameTier, bool home, bool protectedTask) {
        return !expansion && sameTier && home && !protectedTask ? power : Zero;
    }
    bool JoinCohort(float distanceSquared, float radius, int count, int maximum, bool released, bool settled) {
        return radius>Zero && count<maximum && distanceSquared<=radius*radius && (!released || settled);
    }
    int AssistPriority(bool noProduct, bool workerProduct, bool urgent) {
        return noProduct ? -One : workerProduct || urgent ? One : Zero;
    }
    bool CommanderHandoff(bool advancedShipyardComplete,int completedInRange,int required) {
        return advancedShipyardComplete && required>Zero && completedInRange>=required;
    }
    bool CapacityPressure(float income,float usage,float bank,float storage,bool bankPressure) {
        // RECEIVED is deliberately absent: bank/income already include gifts.
        return storage>Zero && bank>=Zero && ((income>usage && bank>=storage*CapacityBankFraction) || bankPressure);
    }
    bool HarborAdmission(bool noYards,bool forward,bool visible) {
        return noYards || (forward && visible);
    }
    bool ExpansionNeedsEscort(float ownDistanceSquared,float enemyDistanceSquared) {
        return ownDistanceSquared>enemyDistanceSquared*SafeExpansionDistanceSquaredRatio; // beyond the safe homeward part of the sea
    }
    bool ExpansionThreatSafe(float threat,float maximum) {
        return threat>=Zero && maximum>=Zero && threat<=maximum; // NaN fails closed
    }
    bool ExpansionFortFunded(float metal,float metalIncome,float energy,float energyIncome,float metalCost,float energyCost) {
        return metalCost>Zero && energyCost>=Zero && metalIncome>Zero && energyIncome>Zero
            && metal+metalIncome*FortificationFundingSeconds>=metalCost+FortificationMetalReserve && energy+energyIncome*FortificationFundingSeconds>=energyCost;
    }
    bool ReplanInvasionSlot(int state, bool footprintClear, bool exitClear) {
        // Missing/exhausted slots have no live frame. Claimed or started slots
        // remain owned by their task even if the buildability probe says no.
        return state<Zero || state==ExhaustedReservationState || (state==AvailableReservationState && (!footprintClear || !exitClear));
    }
    bool SeaSecured(int body, float coverage, int enemies, int quietAge, int requiredQuiet) {
        return body>=Zero && coverage>=UnitValue && enemies==Zero && requiredQuiet>=Zero && quietAge>=requiredQuiet;
    }
    bool InvasionFactoryReady(bool secured, bool protectedSite, bool predecessor, bool windowReady,
        float metalIncome, float energyIncome, float minimumMetalIncome, float minimumEnergyIncome) {
        return secured && protectedSite && predecessor && windowReady && metalIncome>=minimumMetalIncome && energyIncome>=minimumEnergyIncome;
    }
    bool RecoveryLowMetal(bool wasLow,float metal,float storage,float low,float resume) {
        return storage>Zero && metal<storage*(wasLow ? resume : low);
    }
    int RecoveryCount(float income,float fleet,float perIncome,float perFleet) {
        if (fleet<MinimumRecoveryFleetMetal || perIncome<=Zero || perFleet<=Zero) return Zero;
        const int economy=int(income/perIncome), navy=int(fleet/perFleet);
        return One+(economy<navy ? economy : navy);
    }
    bool SeaplaneNext(bool enabled, bool advancedShipyardFinished, int platforms, int queued) {
        return enabled && advancedShipyardFinished && platforms==Zero && queued==Zero;
    }
    bool SeaplaneEconomyReady(bool windowReady, float metalIncome, float energyIncome,
        float availableMetal, float availableEnergy, float metalCost, float energyCost,
        float minimumMetalIncome, float minimumEnergyIncome, float metalReserve, float energyReserve) {
        return windowReady && metalCost>=Zero && energyCost>=Zero && minimumMetalIncome>=Zero && minimumEnergyIncome>=Zero && metalReserve>=Zero && energyReserve>=Zero
            && metalIncome>=minimumMetalIncome && energyIncome>=minimumEnergyIncome && availableMetal>=metalCost+metalReserve && availableEnergy>=energyCost+energyReserve;
    }
    // Centre-out columns keep existing members' slots when reinforcements
    // arrive. Fixed columns avoid a sqrt(N) grid reshuffle at every birth/death.
    int SpreadIndex(int index) { return index==Zero ? Zero : (index%FormationSideCount==One ? (index+One)/FormationSideCount : -index/FormationSideCount); }
    int AAColumn(int slot,int columns) { return SpreadIndex(slot%(columns>Zero ? columns : One)); }
    int AARow(int slot,int columns) { return slot/(columns>Zero ? columns : One); }
    float AASpacing(float configured,float shortestRange) {
        const float overlap=shortestRange*AntiAirRangeSpacingFraction;
        return configured<overlap ? configured : overlap;
    }
    float InterceptLead(float distance,float shipSpeed,float weaponRange,float maximum) {
        if (distance<=weaponRange || shipSpeed<=Zero || maximum<=Zero) return Zero;
        const float seconds=(distance-weaponRange)/shipSpeed;
        return seconds<maximum ? seconds : maximum;
    }
    float RememberThreat(float previous, float observed, int age, int lifetime) {
        return observed>Zero ? observed : age<lifetime ? previous : ZeroValue;
    }
    bool ReleaseFleet(int count, int ageFrames, int desired, int waitFrames) {
        return count>Zero && (count>=desired || ageFrames>=waitFrames);
    }
    // D-341: a cohort that can shoot hovers stands against them when its local
    // surface power is at least `ratio` times the local enemy (hovers included).
    // No armed hover present means no hover decision to make.
    bool HoverSuperior(bool canHitHovers, float ownPower, float enemyPower, float hoverPower, float ratio) {
        return canHitHovers && hoverPower>Zero && ratio>Zero && ownPower>=enemyPower*ratio;
    }
    bool NeedsScreen(float enemySubmarineMetal, float readyCover, float ratio) {
        return enemySubmarineMetal>Zero && readyCover<enemySubmarineMetal*ratio;
    }
    bool NewObjective(int oldTarget, int target, float movedDistanceSquared, int age, int expiry) {
        return oldTarget!=target || movedDistanceSquared>ObjectiveMovementThreshold*ObjectiveMovementThreshold || age>=expiry;
    }
    float ApproachRange(float weaponRange, float sightRange, bool remembered) {
        const float firing = weaponRange*WeaponApproachFraction;
        // A remembered structure is a search position, not fire authority.
        // Stop inside our own sight disc so low-LOS ships can reacquire it.
        const float visual = sightRange*SightApproachFraction;
        return remembered && visual<firing ? visual : firing;
    }
    bool ForwardFootprint(float along, float halfDepth, float frontier, float margin) {
        return halfDepth>=Zero && margin>=Zero && along-halfDepth>=frontier+margin;
    }

    bool RearFootprint(float along, float halfDepth, float margin) {
        return halfDepth>=Zero && margin>=Zero && along+halfDepth<=-margin;
    }
    float ProductionShare(float basePower, float totalBasePower) {
        if (basePower<=Zero || totalBasePower<basePower) return Zero;
        return basePower/totalBasePower;
    }
    bool SupportNeeded(float target, float existing, float factoryPower, float constructionTurretPower, int maximumCount) {
        return constructionTurretPower>Zero && maximumCount>Zero && existing<factoryPower+float(maximumCount)*constructionTurretPower
            && target>=existing+constructionTurretPower*AdditionalTurretDemandFraction;
    }
    float Deficit(float target, float live, float pending) {
        const float value=target-live-pending;
        return value>Zero ? value : Zero;
    }
    // Coverage delivered per construction second, with saturation so one
    // enormous hull is not selected for a tiny missing escort.
    float CounterScore(float deficit, float coverage, float seconds, bool capable) {
        if (!capable || deficit<=Zero || coverage<=Zero || seconds<=Zero) return Zero;
        return (deficit<coverage ? deficit : coverage)/seconds;
    }
    bool RetryBerth(bool active, bool unitAlive, int reservationState) {
        return active && !unitAlive && reservationState==AvailableReservationState;
    }
    bool RestartStability(int since, bool changedSite) { return since<Zero || changedSite; }
    int Missing(int goal, int live, int pending, int batch) {
        const int room = goal - live - pending;
        return room <= Zero || batch <= Zero ? Zero : (room < batch ? room : batch);
    }
    bool TechReady(float metalIncome, float energyIncome, float metalBank, float energyBank,
        float minimumMetalIncome, float minimumEnergyIncome, float metalReserve, float metalPackageCost, float energyPackageCost,
        float horizon, float share) {
        if (metalIncome < minimumMetalIncome || energyIncome < minimumEnergyIncome || metalBank < metalReserve || energyBank < Zero
            || horizon <= Zero || share <= Zero || share > One) return false;
        return metalBank + metalIncome * horizon * share >= metalPackageCost
            && energyBank + energyIncome * horizon * share >= energyPackageCost;
    }
    bool RetireReady(bool replacementComplete, bool exited, bool safe,
        bool tierPreserved, bool currentProduct, float storageRoom, float reclaimMetal) {
        return replacementComplete && exited && safe && tierPreserved
            && !currentProduct && storageRoom >= reclaimMetal;
    }

}
