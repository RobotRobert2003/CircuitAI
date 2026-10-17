// AIR defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/air/air.as
namespace Global {
namespace RoleSettings {
namespace Air {
            // AIR owns these settings and all air.* reservations. TECH never reads them.
            bool ExperimentalBuild = true;
            bool FundFirstLab = false; // balanced opt-in; later factories retain Transition
            float FirstLabFundingSeconds = 180.0f;
            float FirstLabIncomeShare = 0.75f; // leave income and a bank for immediate defence
            bool ContinuousFactoryProduction = true; // refill on completion; funded T2 labs bypass discretionary growth holds
            int MaxProductionBays = 0; // zero: no AIR policy cap; terrain/income/support still gate
            int PlannedT2Bays = 6;
            int PlannedT1Bays = 1;
            int PlannedEcoModules = 4; // one AFUS and eight converter pins each; reservation, not a build order
            // D-292: ordinary fusion is its own module kind (reactor + support bank), planned
            // only once the fusion era starts. Reservation, not a build order.
            int PlannedFusionModules = 2;
            int FusionSupportSlots = 6;
            int FusionModuleFallbackSeconds = 45; // continuous module failure before the logged ring-search fallback
            float EcoFactorySeparation = 384.0f; // districts may abut; native envelopes still exclude overlap
            float EcoReactorSpacing = 512.0f;
            float EcoConverterClearance = 128.0f;
            float OverflowGrowthSeconds = 180.0f;
            int ConverterParallel = 3;
            float ConverterDraw = 70.0f;
            float ConverterEnergyReserve = 150.0f;
            int T2NanoSoftLimit = 20;
            int T2ExpansionSupport = 20; // completed turrets per existing T2 air lab; banked metal cannot bypass
            int T1NanoLimit = 5;
            int OpeningNanoCount = 2; // completed support near the first T1 plant before the opening raid
            bool T1OpeningRaidEnabled = true;
            int T1OpeningBomberMin = 1;
            int T1OpeningBomberMax = 10;
            int MaxT1EconomyBuilders = 40;
            int MaxT2EconomyBuilders = 24;
            float HomeMexRadius = 1400.0f;
            float HomeEconomyRadius = 2400.0f;
            float HomeDefenceRadius = 1500.0f;
            float AntiNukeCoreRadius = 800.0f;
            float AntiNukeMetalIncome = 40.0f;
            float AntiNukeEnergyIncome = 1200.0f;
            int AntiNukeAfterSeconds = 15 * 60;
            int EnergyParallel = 6;
            float SmallProjectSeconds = 12.0f;
            float ReactorProjectSeconds = 120.0f;
            int ConstructorsPerFighter = 2;
            int CombatOrdersPerEconomyConstructor = 2; // after opening screen, even during sustained incursions
            bool StrikeCleanupMobile = false; // preserve T1 exclusion unless explicitly enabled
            int InterceptUpdateSeconds = 2;
            float InterceptCostRatio = 1.5f;
            float WorkforceHorizonSeconds = 60.0f;
            float WorkforceReserveMetal = 100.0f;
            float WorkforceReserveEnergy = 200.0f;
            float WorkforceHighFill = 0.9f;
            float WorkforceLowFill = 0.65f;
            float WorkforceRefillLow = 0.8f;
            float WorkforceRiseMetal = 30.0f;
            int WorkforcePressureSeconds = 15;
            int WorkforceSafetyConstructors = 128; // pressure can exceed the ordinary tier ceilings
            int WorkforceSupportBatchMax = 8; // safety bound, actual batch is capacity/funding limited
            float WorkforceSupportSeconds = 30.0f;
            float WorkforceMinJobSeconds = 6.0f;
            float WorkforceStallSeconds = 10.0f;
            int EcoSupportSlots = 12;
            float WindClusterGap = 144.0f;
            int EconomySearchRings = 24;
            int CompactCampusAfterSeconds = 180; // rough land: rotate/narrow/split failed six-lab plans
            int FirstFusionTargetSeconds = 20 * 60;
            int FirstFusionLeadSeconds = 12 * 60;
            int PreFusionMexLimit = 6;
            float FusionAccessMinMetal = 12.0f;
            float FusionAccessMinEnergy = 450.0f;
            float WarmFactoryGapSeconds = 0.5f; // prior until measured; not cold opening time
            float ProductionIncomeShare = 0.65f;
            float TransitionMinMetal = 50.0f;
            float T1BomberMetalStep = 8.0f;
            int T1BomberCap = 12;
            float T1SupportMetalStep = 4.0f;
            int T1SupportCap = 16;
            float TransitionMinEnergy = 1200.0f;
            int TransitionEarliestSeconds = 8 * 60;
            int HomeFighterFloor = 6;
            int HomeFighterCeiling = 60;
            int OpeningAirConstructors = 3;
            float CommanderEconomyRadius = 900.0f;
            float HomeAirValueRatio = 1.2f;
            int BomberOrdersClear = 6; // discretionary orders per ten, not resource percentages
            int BomberOrdersParity = 3;
            int StrikeFirstSize = 8; // legacy compatibility; experimental opening uses the range below
            int FirstBomberWaveMin = 10;
            int FirstBomberWaveMax = 20;
            float TechEconomyMinMetal = 50.0f;
            int MassBomberAfusCount = 2; // economic growth goal, not a production gate
            float BomberSustainableMetal = 30.0f;
            float StrikeEscortLead = 480.0f;
            float StrikeBacklineRiskLimit = 500.0f;
            float StrikeDistrictRadius = 1800.0f;
            bool StrikeEarlyAttack = true; // ATTACK before the final approach MOVE
            float StrikeImmediatePriority = 4.0f; // visible local AFUS interrupts a committed raid; 0 disables
            float StrikeImmediateRadius = 1800.0f;
            int RadarWaveSize = 20;
            int RadarWaveIntervalSeconds = 600;
            int RadarMaxWaitSeconds = 90; // launch available planes even below the full cohort
            int RadarPatrolCheckSeconds = 2;
            float RadarPatrolRadius = 280.0f;
            float RadarThreatPadding = 320.0f;
            float RadarSafeThreat = 0.0f;
            int RadarPatrolGrid = 14; // bounded candidate lattice, not a map-wide path search
            bool NavalSupportEnabled = true;
            int NavalSupportCheckSeconds = 5;
            float NavalSupportRadius = 2400.0f;
            float NavalSupportFriendlyRadiusFactor = 1.25f;
            float NavalSupportMinDeficit = 300.0f;
            float NavalSupportReserveFactor = 1.25f;
            int NavalSupportMinWave = 2;
            int NavalSupportMaxWave = 60;
            int NavalSupportMaxWaitSeconds = 90;
            float NavalSupportApproach = 1100.0f;
            float NavalSupportMaxThreat = 180.0f; // existing threat-grid units; verified in supplied cases
            int NavalSupportSearchSeconds = 20;

            bool BaseResponseEnabled = true;
            float BaseResponseRadius = 1800.0f;
            int BaseResponseSearchSeconds = 20;
            int BaseResponseGunships = 20; // one shared reserve, including frames/orders
            int BaseResponseEmpSupport = 4;
            int BaseResponseMinWave = 4;
            int BaseResponseMaxWave = 30;
            int BaseResponseMaxWaitSeconds = 45;
            float BaseResponseGroundRatio = 0.35f;
            float BaseResponseAaRatio = 2.0f;
            float BaseResponseThreatRadius = 1000.0f;
            float BaseResponseAssemblyRadius = 700.0f;
            bool BaseResponsePrioritizeAntiAir = true;
            float BaseResponseLightStaticAntiAirMaximumMetal = 400.0f;
            float RadarSightOverlap = 0.5f; // linear overlap of neighbouring ground-LOS diameters
            float RadarAssemblyRadius = 480.0f; // fixed-wing aircraft circle their assigned positions
            float RadarBacklineInset = 256.0f;
            int MassBomberOrdersClear = 8;
            int MassBomberOrdersParity = 5;
            float StrikeReserveSeconds = 120.0f;
            float StrikeUnknownReserve = 0.25f;
            float StrikeRiskScale = 0.002f;
            float StrikeArmyReserve = 0.15f;
            float StrikeLocalAaReserve = 0.5f;
            float StrikeLossGrowth = 1.5f;
            float StrikeRiskRecovery = 0.9f;
            float StrikeLearnedRiskMax = 3.0f;
            float StrikeFailedSurvival = 0.25f;
            int StrikeFailedRetrySeconds = 300;
            float StrikeFailedRegionRadius = 640.0f;
            float StrikeCorridorPadding = 320.0f;
            float StrikeEdgeInset = 480.0f;
            bool StrikeSynchronize = true;
            int T1RaidMinimum = 3;
            int StrikeWaveCap = 80;
            int StrikeCadenceSeconds = 4 * 60;
            float StrikeBudgetShare = 0.35f;
            float StrikeFormationWidth = 1320.0f;
            float StrikeAssemblyRadius = 600.0f; // measured fixed-wing arrival tolerance, not lane spacing
            float StrikeAssemblyFraction = 0.8f;
            int StrikeJoinSeconds = 20;
            float StrikeLaneSpacing = 180.0f;
            float StrikeRankSpacing = 240.0f;
            float StrikeLossAbort = 0.35f;
            float StrikeDamageMargin = 1.3f;
            float StrikePassFraction = 0.4f;
            float StrikeThreatWeight = 1.0f;
            float StrikeMaxThreat = 1500.0f;
            float StrikeMinTargetMetal = 70.0f;
            int ScoutReplaceSeconds = 120;
            int ScreenFullFighters = 40;
            int ScreenCells = 8;
            float ScreenRearWidth = 600.0f;
            // Full-strength patrols span the map, using cached legal visibility.
            float ScreenMapInset = 128.0f;
            int ScreenVisibilitySamples = 24;
            float ScreenFogSetback = 256.0f;
            float ScreenAdvanceHysteresis = 384.0f;
            float ScreenThreatPadding = 192.0f;
            float ScreenDangerRetreatStep = 512.0f;
            float ScreenRearAdvance = 400.0f;
            float ScreenFrontSetback = 600.0f;
            int CapacityStableSeconds = 20;
            int TelemetrySeconds = 10;
            bool WaveAvoidHomeFocus = true;
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for AIR role
            /******************** AIR BASE SETTINGS ********************/
            // All settings applied to air role at game start, logic can change throughout game
            float AllyRange = 1600.0f;

            /******************** AIR MILITARY QUOTAS ********************/
            // Scout unit cap for AIR role
            int MilitaryScoutCap = 10;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 1.0f;
            float MilitaryRaidAvgPower = 1.0f;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system for AIR role.
            // When enabled, AIR factories (T1/T2 aircraft plants, gantries that
            // produce aircraft, etc.) delegate unit selection to
            // FactoryProduction::MakeTask using threat-aware scoring.
            bool UseDynamicFactoryProduction = false;
            /******************** AIR DYNAMIC QUOTA SETTINGS ********************/
            // Enemy surface cost multiplier used to determine when AIR is underpowered.
            // If our estimated army metal cost is below enemySurfaceCostPerPlayer * multiplier,
            // AIR is considered underpowered and will switch to more aggressive quotas.
            float DynamicQuotaEnemyCostThresholdMultiplier = 0.9f;

            // Underpowered quotas: used when AIR is behind in army power vs enemy surface cost.
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;

            // Delay (in seconds) before AIR starts applying dynamic quota adjustments.
            // Mirrors Front role behavior but scoped to AIR so roles can diverge if needed.
            int DynamicQuotaDelaySeconds = 5 * 60;

            /******************** AIR ECONOMY SETTINGS ********************/
            // Mostly delegate economy to AI for air, but give it an early start

            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f; 

            // T1 Energy converter policy (Air-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 20.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;

            //Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 1100.0f; 

            //Stop building advanced solar if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1200.0f; 
            int AdvancedSolarEarliestSeconds = 5 * 60;
            float AdvancedSolarMinimumMetalIncome = 15.0f;
            float AdvancedSolarMinimumMetalCurrent = 250.0f;

            // Prefer cheap wind generators before advanced solar when CircuitAI's
            // effective average wind output exceeds BAR's good-wind threshold.
            float GoodWindMinimumEnergy = 7.0f;
            int CommanderWindTargetCount = 6;
            float CommanderWindEnergyIncomeTarget = 300.0f;
            float CommanderWindMinimumMetalCurrent = 80.0f;

            /******************** T2 AIRCRAFT PLANT THRESHOLDS (AIR role) ********************/
            // Economy thresholds and caps for building a T2 Aircraft Plant when in AIR role
            // Defaults mirror TECH thresholds but are scoped to AIR so air.as does not reference TECH settings.
            float RequiredMetalIncomeForT2AircraftPlant = 30.0f;
            float RequiredMetalCurrentForT2AircraftPlant = 50.0f;
            float RequiredEnergyIncomeForT2AircraftPlant = 1200.0f;
            int MaxT2AircraftPlants = 1;

            /******************** PORC: AIR DENIAL ********************/
            // AIR porcs earlier, harder, and for the whole team. Global::Porc
            // decides when a cluster gets the full chain (by time or income)
            // and how big each visit's budget is; these override it in
            // Air_Init so AIR reaches full porc mid game rather than late.
            int PorcLateGameMinutes = 12;
            float PorcLateGameMetalIncome = 50.0f;
            float PorcLateGameEnergyIncome = 800.0f;
            float PorcLateBudgetMod = 1.5f;
            // Build anti-air in allied clusters too (native porcAllyAA): the
            // enemy air goes where the allies are, and ground defence there
            // stays the ally's own business.
            bool PorcAlliedClustersAA = true;

            /******************** LATE-GAME EXPANSION ********************/
            // AIR sat at max metal late: one T2 air plant, nanos capped by
            // income, and nothing else to spend on. This ladder runs while
            // metal is floating and turns the surplus into build power, more
            // air production placed on a ring well outside the core, the energy
            // to carry it, and finally a gantry - the only route to T3 air,
            // since the experimental air plant is built solely by the T3 air
            // constructor the gantry produces.
            // "Floating": aiEconomyMgr.isMetalFull (> 80% of storage), or
            // current above LateMetalCurrent - and income above LateMetalIncome
            // either way, so a full bank on a dead economy does not trigger it.
            float LateMetalCurrent = 2500.0f;
            float LateMetalIncome = 35.0f;
            // Ring the late structures are placed on, around the start position,
            // and the site-search radius each gets. This is what grows the base.
            float LateExpansionRadius = 1400.0f;
            float LateExpansionShake = 384.0f;   // SQUARE_SIZE * 48
            int LateRingSlots = 6;
            // Build power first: nanos per T2 air plant beyond the income target.
            int LateNanosPerT2Plant = 4;
            // Then production: total T2 air plants allowed while floating.
            int LateMaxT2AircraftPlants = 3;
            // Then energy: one fusion per this much energy income shortfall, and
            // an advanced fusion once income and bank both clear these.
            float LateEnergyPerT2Plant = 900.0f;
            float LateAFUSMetalIncome = 60.0f;
            float LateAFUSMetalCurrent = 6000.0f;
            // Then T3: a gantry once this rich. Gantry production is
            // FactoryProduction's business (EnqueueGantrySignatureBatch).
            float LateGantryMetalIncome = 60.0f;
            float LateGantryMetalCurrent = 6000.0f;

            /******************** AIR NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            // Maximum staged T1 air-constructor target. When enabled, the first
            // is unconditional; later constructors require the thresholds below.
            int MinT1AirConstructorCount = 3;
            float SecondT1AirConstructorMetalIncome = 8.0f;
            float SecondT1AirConstructorEnergyIncome = 160.0f;
            float ThirdT1AirConstructorMetalIncome = 18.0f;
            float ThirdT1AirConstructorEnergyIncome = 300.0f;

            // Maximum staged T2 air-constructor target. When enabled, the first
            // is unconditional.
            int MinT2AirConstructorCount = 2;
            float SecondT2AirConstructorMetalIncome = 40.0f;
            float SecondT2AirConstructorEnergyIncome = 1200.0f;

            // Minimum number of air scouts to maintain globally for early map vision
            int MinAirScoutCount = 1;

            // Small economy-gated interception reserve. Dynamic/native production
            // handles additional air-defense demand.
            int MinT1FighterCount = 2;
            float T1CombatProductionMetalIncome = 12.0f;
            float T1CombatProductionEnergyIncome = 250.0f;

            /******************** EARLY BUILD-POWER FOCUS ********************/
            // Keep one strategic lane and one expansion lane until the economy is
            // established or the deadline expires. Additional constructors assist
            // those active lanes.
            int BuildFocusDeadlineSeconds = 6 * 60;
            float BuildFocusMetalIncome = 20.0f;
            float BuildFocusEnergyIncome = 300.0f;
            int BuildFocusAssistTimeoutSeconds = 15;
            int BuildFocusIdleWaitSeconds = 5;

            // One-time T1 strike package. Keep this small so it does not delay economy growth.
            int T1StrikeOpenerSize = 3;
            float T1StrikeOpenerMinimumMetalIncome = 12.0f;
            float T1StrikeOpenerMinimumEnergyIncome = 250.0f;

            /******************** T2 BOMBER WAVES ********************/
            // T1 bombers keep the native trickle (each bomber attacks as it is built).
            // T2 bombers are held at base with an escort of T2 fighters and released
            // together in waves that grow from FirstSize towards MaxSize. The sizing
            // algorithm and the native primitives are documented in manager/air_waves.as.
            bool BomberWavesEnabled = true;
            int BomberWaveFirstSize = 20;          // bombers in the first wave, and the floor
            int BomberWaveMaxSize = 300;           // hard cap on bombers per wave
            float BomberWaveFighterRatio = 1.0f;   // fighters held per bomber before a launch
            // Escorts do not soak AA (bombers are AA's first priority), so they
            // are only worth delaying a wave for when the enemy flies. Below the
            // first figure no escort is held; at the second the full ratio is.
            float EscortMinEnemyAirCost = 300.0f;
            float EscortFullEnemyAirCost = 3000.0f;
            // D-291: when every bomber of an offensive operation (T2 wave or T1 raid) is
            // dead, its surviving escort fighters fan out beyond the enemy base to scout,
            // then return to the home screen on arrival or timeout. Defensive sorties and
            // naval escorts are excluded. EscortScoutMax is a safety bound, not a behaviour cap.
            bool EscortScoutEnabled = true;
            int EscortScoutMax = 32;
            int EscortScoutPerBase = 8;            // fan slots per enemy base before the next base/layer
            float EscortScoutFanDegrees = 140.0f;  // fan width centred on our-base -> their-base axis
            float EscortScoutDepth = 900.0f;       // elmos beyond the enemy start
            float EscortScoutLayerStep = 450.0f;   // extra depth per further layer of fans
            float EscortScoutMinSpacing = 320.0f;  // scout points of one wipe are at least this far apart
            float EscortScoutExitDistance = 700.0f; // ignore the first part of the leg (inside the umbrella that killed the bombers)
            float EscortScoutThreatPadding = 128.0f;
            // Threat-grid units (aiBattle.AirThreatAlong: the highest threat cell touched,
            // or 1.0 when only a visible AA range intersects), the scale of
            // NavalSupportMaxThreat and StrikeMaxThreat. The destination must be clear
            // of known AA; the leg may cross the base the fighters are already over.
            float EscortScoutSafeThreat = 0.0f;     // first candidate at or below leg+point risk is taken
            float EscortScoutMaxThreat = 1.0f;      // destination at or above: under known AA; fighter goes home
            float EscortScoutMaxLegThreat = 1500.0f; // leg beyond the exit distance at or above: fighter goes home
            int EscortScoutPendingSeconds = 10;    // planned point expires if the fighter does not idle in time
            int EscortScoutLingerSeconds = 4;      // seconds at the point before returning
            int EscortScoutTimeoutSeconds = 75;
            // Growth applied to the previous wave size from its survival ratio, measured
            // EvaluateSeconds after launch: heavy losses mean the enemy anti-air is winning
            // and the next wave needs mass; light losses grow gently.
            float BomberWaveLowSurvival = 0.4f;
            float BomberWaveHighSurvival = 0.8f;
            float BomberWaveGrowthOnHeavyLoss = 2.0f;
            float BomberWaveGrowthDefault = 1.5f;
            float BomberWaveGrowthOnLightLoss = 1.25f;
            int BomberWaveEvaluateSeconds = 120;
            // Enemy anti-air floor: the wave's bomber metal must reach this fraction of the
            // enemy anti_air metal on the map (Military cost cache, refreshed every update).
            float BomberWaveEnemyAAMetalFraction = 0.5f;
            // Launch anyway once FirstSize bombers have been held this long, so production
            // that cannot reach the target in time never stalls the air war.
            int BomberWaveMaxHoldSeconds = 8 * 60;
            // After a launch, released units re-enter Military::AiMakeTask within a few
            // seconds; units that ask later than this rejoin the hold instead.
            int BomberWaveReleaseWindowSeconds = 15;
            // Minimum metal income before the T2 plant produces wave aircraft.
            float BomberWaveProductionMetalIncome = 40.0f;
            // Income floor on the wave size (D-045): every IncomeStep of metal
            // income adds SizePerIncomeStep bombers to what a wave must hold
            // before it launches - at +100 a wave is 50, at +200 it is 100.
            // The survival growth still applies above the floor.
            float BomberWaveIncomeStep = 100.0f;
            int BomberWaveSizePerIncomeStep = 50;

            /******************** WAVE ATTACK METHODS ********************/
            // Each launch draws a method by these weights (doc/air-wave-attacks.md).
            // 0 removes a method.
            float WaveWeightCarpet = 3.0f;
            float WaveWeightFlank = 2.0f;
            float WaveWeightPincer = 1.0f;
            float WaveWeightStrike = 2.0f;
            float WaveWeightDeep = 1.0f;
            float WaveWeightFeint = 1.0f;
            // Geometry, elmos: the line forms FormDistance short of the aim,
            // lanes Spacing apart, and runs Overrun past it.
            float WaveFormDistance = 1400.0f;
            float WaveLaneSpacing = 96.0f;
            float WaveOverrun = 900.0f;
            int WaveFormTimeoutSeconds = 45;   // go anyway if the line is not formed by then
            float WaveFlankMinDeg = 55.0f;     // FLANK bearing off the base->aim line
            float WaveFlankMaxDeg = 95.0f;
            float WavePincerDeg = 45.0f;       // PINCER: both lines this far off the line
            int WaveFeintHoldSeconds = 25;     // FEINT: hold the formed line this long
            // STRIKE / DEEP target filter: statics at or above this cost, plus T3 ("heavy") mobiles.
            float WaveStrikeMinStaticCost = 2500.0f;

            /******************** HEAVY AIR STRIKE POLICY (Legion/Cortex) ********************/
            // Maintain a bounded late-game heavy-air force for Legion/Cortex.
            float T2HeavyAirIncomeThreshold = 250.0f;
            int T2HeavyAirTargetCount = 6;
            int T2HeavyAirBatchPerFactory = 2;

            /******************** COMMANDER FACTORY ASSIST ********************/
            // Maximum time spent assisting the opening aircraft plant. Assistance
            // ends sooner as soon as the first construction aircraft is complete.
            int CommanderFactoryAssistDeadlineSeconds = 90;

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 aircraft plant. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks

        }
}
}
