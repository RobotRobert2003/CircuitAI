// SEA defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/sea/sea.as
namespace Global {
namespace RoleSettings {
namespace Sea {
            bool CoordinateTech = true;
            float TechYardTargetSeconds = 90.0f;
            int TechMinimumTurrets = 2;
            float TechHomeHarborRadius = 1200.0f;
            // D-343: a teammate's finished naval yard within TechHomeHarborRadius
            // counts as home for admitting a first T2 yard (crowded shared coast).
            bool AlliedHarborIsHome = true;
            bool TechReclaimT1 = true;
            float RearEconomyDistance = 650.0f;
            float ConversionGrowthStep = 150.0f;
            // Provisional basin control never equates missing contacts with victory.
            int SeaControlQuietSeconds = 90;
            int SeaControlSurveySeconds = 180;
            float SeaControlSurveyFraction = 0.60f;
            float SeaControlMinimumFleet = 600.0f;
            float ShoreAlliedAssetRadius = 640.0f;
            float ShoreStationCoverageRadius = 640.0f;
            float ExpansionRadarSpacing = 1400.0f;

            // D-268: shared shoreline intelligence and regional naval policy.
            bool CoordinatedFleet = true;
            int ShoreAccessCandidatesPerTick = 24;
            // Public 64-elmo terrain cells: exclude small rocks and narrow fragments.
            int ShoreMinimumLandCells = 64;
            array<string> ShoreFactoryDefinitions = {"armlab", "corlab", "leglab"};
            float ShoreFactoryClearance = 32.0f;
            float ShoreFactoryHeightVariation = 12.0f;
            float ShoreFactoryMaximumGrade = 0.25f;
            float ShoreFactoryAccessRadius = 640.0f;
            int ShoreMinimumInteriorCells = 16;
            int SubmarinePerimeterGroupSize = 4;
            int ConstructorShoreRevisitSeconds = 90;
            int OtherShoreRevisitSeconds = 180;
            int InteriorRevisitSeconds = 300;
            float ShoreTravelScoreScale = 12000.0f;
            float ShoreEnemyDistanceWeight = 2.0f;
            // Scout sight must cover shallow offshore yard sites as well as
            // the first water cell. This does not move submarine shore anchors.
            float ScoutShoreProbeRadius = 640.0f;
            // A due enemy beach outranks a first look at an ordinary shore.
            // Fresh sectors still cool down, leaving time for general survey.
            int EnemyShoreScoutPriority = 6;
            int EnemyShoreEdgeBonus = 3; // Edge approaches outrank interior beach revisits.
            int EnemyShoreRevisitSeconds = 45; // eligibility plus travel must fit an early-warning cycle
            float ScoutShoreSeparation = 960.0f;
            bool ScoutEdgeOverwatch = true;
            float ShoreApproachGrade = 0.65f; // Ranking hint; native movement remains authoritative.
            float SubmarineFocusRadius = 2200.0f;
            float SubmarineAdvanceStep = 512.0f;
            float SubmarineLineSpacing = 96.0f;
            int SubmarineDepartureCount = 3;
            int SubmarineDepartureSeconds = 30;
            bool BalancedFleetComposition = true;
            int FleetRecruitBatch = 3;
            // Ordered submarine / surface screen / heavier surface hull.
            // T2 retains existing T1 yards and their useful frigate baseline.
            array<string> ArmadaTierOneComposition={"armsub","armpship","armroy"};
            array<string> CortexTierOneComposition={"corsub","corpship","corroy"};
            array<string> LegionTierOneComposition={"legnavysub","legnavyfrigate","legnavydestro"};
            array<string> ArmadaTierTwoComposition={"armserp","armlship","armcrus"};
            array<string> CortexTierTwoComposition={"corssub","corfship","corcrus"};
            array<string> LegionTierTwoComposition={"leganavyheavysub","leganavyantiswarm","leganavycruiser"};
            float SubmarineCompositionRatio = 1.0f;
            float FrigateCompositionRatio = 1.0f;
            float DestroyerCompositionRatio = 1.0f;
            int FrigatesPerAntiAirShip = 5;
            // D-301 naval meta review: per-faction {sub, screen, heavy} count
            // ratios, replacing the flat 1:1:1 (the three ratios above stay as
            // the fallback for a profile that empties these arrays).
            // Armada T1: Corsair core, ~2 Ellysaw per Corsair, Eels a minority.
            // Cortex T1: Riptide:Oppressor ~5:2 (Build Atlas, Supreme 8v8).
            // Legion T1: Argonaut (anti-sub) : Syracusia (no ASW) ~3:1.
            // T2: the cruiser (Paladin/Buccaneer/Thalassa) is the core.
            array<float> ArmadaTierOneRatios={0.5f,2.0f,1.0f};
            array<float> CortexTierOneRatios={0.5f,2.5f,1.0f};
            array<float> LegionTierOneRatios={0.5f,3.0f,1.0f};
            array<float> ArmadaTierTwoRatios={0.5f,0.5f,2.0f};
            array<float> CortexTierTwoRatios={0.5f,0.5f,2.0f};
            array<float> LegionTierTwoRatios={0.5f,0.5f,2.0f};
            // D-301 capital step at the T2 yard: a battleship behind every
            // CruisersPerBattleship cruisers (from CapitalAfterCruisers, at
            // most MaxBattleships); shore siege ships once the fleet holds
            // SiegeFleetMetal, one per SiegeShipFleetMetal (max MaxSiegeShips).
            bool CapitalShips = true;
            int CapitalAfterCruisers = 4;
            int CruisersPerBattleship = 3;
            int MaxBattleships = 3;
            float SiegeShipFleetMetal = 5000.0f;
            int MaxSiegeShips = 4;
            float TierOneSiegeFleetMetal = 3000.0f; // Legion Octeres at the T1 yard
            int MaxTierOneSiegeShips = 2;
            // Siege hulls (no anti-sub weapon) wait while at least this much
            // known enemy submarine metal is on the home water.
            float SiegeMaxEnemySubMetal = 400.0f;
            // D-301: T2 AA ships (and Legion's Iapetus) escort the fleet
            // instead of patrolling home; an armed warship within its engage
            // range of a cohort is scored x EngagedTargetMultiplier.
            bool FleetAAEscort = true;
            // D-301: coast support only bombards targets the station outranges.
            float CoastStandoffMargin = 64.0f;
            float CoastCommanderReach = 450.0f;
            // Coast stations also stay outside every other known armed ground
            // contact's reach (+CoastStandoffMargin), not only the target's.
            bool CoastAllCover = true;
            float EngagedTargetMultiplier = 3.0f;
            float EngagedTargetMargin = 300.0f;
            float FrigateFiringRangeFraction = 0.85f;
            float FrigateKiteRangeFraction = 0.65f;
            int FrigateMovementCommitSeconds = 4;
            // KI-611: gun hulls that outrange a hover kite it, holding fire from
            // outside its reach plus this margin (elmos).
            bool HoverKite = true;
            // KI-611: hulls that cannot out-trade an armed hover (no gun,
            // hover-blind, siege, or a gun that does not outrange it) step
            // home when one is within its reach plus this margin (elmos).
            bool HoverEvade = true;
            // KI-611: Legion drone carriers (legdrone). Their objective score
            // is multiplied so the fleet kills the carrier, not the drones.
            array<string> DroneCarrierHulls={"legnavydestro","leganavyantinukecarrier","legfhive","legspcarrier"};
            float DroneCarrierMultiplier = 2.0f;
            float HoverEvadeMargin = 200.0f;
            // TechYard re-staffs an abandoned first advanced-yard frame. Off:
            // in 25-minute head-to-head play, finishing T2 every game cost more
            // fleet than it returned (s28 against s25).
            bool TechRestaffFrame = false;
            // KI-611: hulls whose only weapons cannot target hovers (BAR
            // NOTHOVER torpedoes: the Legion Argonaut). They never take a
            // hover objective; when enemy hovers hold HoverResponseMetal on
            // the home water, HoverResponseShare of that hull's composition
            // share moves to the gun hull (the heavy slot).
            array<string> HoverBlindHulls={"legnavyfrigate"};
            float HoverResponseMetal = 1200.0f;
            float HoverResponseShare = 0.75f;
            float HoverKiteMargin = 60.0f;
            // D-341: a gun cohort whose local surface power is at least this many
            // times the local enemy (armed hovers included) stands against hovers:
            // no HoverEvade step-away, no HoverKite back-off, and an uncatchable
            // hover chase ends at the engagement anchor instead of a withdrawal.
            // Lower = bolder. 0 disables (always the cautious D-302 micro).
            float HoverHoldAdvantage = 2.0f;
            // D-342: seconds a tidal/converter/fusion may find no water-layout site
            // (crowded allied coast) before SEA keeps the native placement for it.
            // 0 keeps layout-only placement (the old behaviour).
            int LayoutFallbackSeconds = 60;
            // D-343: every SEA economy/turret reservation must leave the side's
            // flagship a path from each yard's exit mouth LanePathDistance out to
            // open water and RearPathDistance back behind the yard.
            bool FlagshipPathCheck = true;
            float LanePathDistance = 800.0f;
            float RearPathDistance = 900.0f;
            // D-343: finished yards (own and teammates') within this distance of a
            // new SEA reservation are path-checked; farther yards cannot be affected.
            float YardPathRadius = 2500.0f;
            // D-343: when the planned turret block cannot fit behind the harbor,
            // search rings around the shipyard and shrink the block (4x4 to 2x2).
            bool DynamicTurrets = true;
            // D-343: an economy zone that touches a teammate's reservation is
            // shrunk clear of it instead of being refused whole (shared coasts).
            bool ZoneAroundAllies = true;
            // D-344: converter annexes a full economy block may grow (0 disables),
            // and ring candidates tried per ask (one ask every two seconds at most).
            // Diagnostic [SEA][State]: ships within this distance of the start count as home.
            float DiagnosticHomeRadius = 1500.0f;
            // D-346: damaged ships fall back just outside known enemy reach
            // (+ ForwardRepairBuffer) and wait there to be healed, instead of
            // sailing to base. false restores the base retreat.
            bool ForwardRepair = true;
            // D-347: a rez sub keeps a resurrection this long before it may be
            // reassigned (repair jobs used to interrupt it every 2 s).
            int RecoveryResurrectCommitSeconds = 120;
            // D-348: route-order volume (2026-10-19 online lag with 144 subs).
            int FleetRerouteSeconds = 3;        // same-target re-route interval
            int FleetRoutesPerTick = 16;        // combat re-routes per census, rest next census
            bool MergeChasingCohorts = true;    // one pack per hull chasing one target
            float ChaseMergeRadius = 900.0f;
            float ForwardRepairBuffer = 250.0f;
            float ForwardRepairHealth = 0.75f;     // publish a point below this health
            float ForwardRepairMaxDistance = 2000.0f;
            int ForwardRepairSeconds = 30;         // a point expires unless renewed
            float UnknownContactRange = 500.0f;    // sonar contact with no definition
            int ConverterAnnexes = 4;
            int AnnexCandidates = 6;
            float SubmarineRetreatRadius = 2000.0f;
            // Lost-water recovery only; ordinary naval economy/combat is unchanged.
            bool CoastalFallback = true;
            int CoastLossSeconds = 30;
            int CoastRetakeSeconds = 60;
            float CoastDepotDistance = 800.0f;
            float CoastT2MetalIncome = 25.0f;
            float CoastT2EnergyIncome = 600.0f;
            bool AmphibiousInvasion = true;
            int InvasionSurveySeconds = 600; // all 64-elmo water samples need LOS AND sonar
            int InvasionQuietSeconds = 30;
            float InvasionEscortMetal = 1500;
            float InvasionOffshoreDistance = 640;
            float InvasionWeaponMargin = 256;
            float InvasionMinMetal = 60, InvasionMinEnergy = 1200;
            float InvasionGantryMetal = 150, InvasionGantryEnergy = 5000;
            int InvasionLabTurrets = 6, InvasionGantryTurrets = 12;
            int InvasionWaveSize = 6, InvasionWaveSeconds = 90;
            bool CompactEconomy = true; // compact layout/economy policy; independent of experimental fleet/production
            int EconomyTurretSide = 4;
            int TidalClusterSites = 48;
            float FactoryEconomyClearance = 128.0f;
            int FusionMinimumTurrets = 2;
            // SEA layout economies size conversion from actual surplus, not
            // the legacy 40 M/s ceiling (still retained for legacy callers).
            int ConverterParallelProjects = 3;
            float ConverterEnergyReserve = 100.0f;
            float FusionBudgetSeconds = 360.0f;
            float EconomyBlockRadius = 1400.0f;
            // D-188: independent policy over the shared native reservation engine.
            bool ExperimentalBuild = false;
            bool ForwardHarbors = true;
            bool AdaptiveFleet = true; // SEA combat is independent of base-layout migration
            bool FleetOperations = true;
            bool FleetAttackKnownBases = true;
            bool SubmarineHoldFireline = true;
            float SubmarineReplacementRatio = 1.15f;
            float SubmarineReplacementRadius = 384.0f;
            int SubmarineReplacementSeconds = 90;
            int SubmarineReplacementHoldSeconds = 60; // D-348: a reserve held this long joins the fight
            array<string> FirelineSubmarineDefinitions = { "armsub", "corsub", "legnavysub" };
            // Master switch for SEA per-hull MOVE compaction (D-243).
            bool CompactMoveRoutes = true;
            // D-340: also compact every untargeted route (withdrawal, hold, screen,
            // escort, assembly, coast). Only a close targeted approach stays exact.
            // false restores D-243's transit-only gate.
            bool CompactUntargetedRoutes = true;
            bool VerifyPowerIndex = false; // correctness games only; duplicates the legacy scan
            // D-231: SEA-only mission, grouping and economic growth controls.
            float RecoveryOpportunityMultiple = 3.0f;
            float FleetRowSpacing = 96.0f;
            float FleetCohortRadius = 720.0f;
            int FleetCohortMaximum = 24;
            float FleetPursuitLeash = 1000.0f;
            float FleetClosingSeconds = 12.0f;
            float FleetRepairHealth = .45f;
            int FleetFailureSeconds = 30;
            float GrowthHomeRadius = 1600.0f;
            float GrowthReserveShare = .45f;
            float EnergyBufferSeconds = 12.0f;
            int ExpansionCandidates = 5;
            // D-300 surface task force: same-body surface combat cohorts
            // within TaskForceRadius of the lead share its target and goal.
            bool SurfaceTaskForce = true;
            float TaskForceRadius = 2200.0f;
            int FleetReleaseCount = 7;
            int FleetReleaseSeconds = 60;
            int FleetSearchSeconds = 45;
            array<string> CombatSubmarineDefinitions = { "armsub", "corsub", "legnavysub", "armserp", "corssub", "armsubk", "corshark", "leganavyheavysub", "leganavybattlesub" };
            float SubmarineShoreMinimumDistance = 0.0f;
            float SubmarineShoreRangeFraction = 0.95f;
            float SubmarineShoreSafetyMargin = 96.0f;
            float SubmarinePerimeterMaximumThreat = 0.1f;
            int SubmarinePerimeterSeconds = 90;
            int SubmarinePerimeterCandidates = 32;
            float FleetScreenRadius = 1100.0f;
            float FleetScreenRatio = 1.2f;
            float FleetLaneSpacing = 72.0f;
            int FleetScouts = 3;
            // D-300: small-boat waste (27 Skaters built, 24 lost in a natural
            // Supreme game). Losses beyond the first live scout are replaced
            // after ScoutReplacementSeconds; Skater/scout boats from every
            // channel (scout floor, air counter, composition AA) are capped at
            // min(SmallBoatMax, SmallBoatBase + fleet metal / SmallBoatFleetMetal).
            // KI-610: scouts treat known armed enemy ships as threat (range + margin).
            bool ScoutAvoidShips = true;
            float ScoutShipMargin = 200.0f;
            float ScoutReplacementSeconds = 120.0f; // D-301: was 90 (still 10-12 built per game)
            int SmallBoatBase = 2;
            int SmallBoatMax = 4; // D-301: meta ~1 per 6-10 ships; was 6
            float SmallBoatFleetMetal = 1500.0f;
            int SmallBoatAirMax = 8;            // D-301: AA-counter budget when enemy air is the deficit layer
            float SmallBoatAirFleetMetal = 750.0f;
            bool T1SubmarinesAfterT2 = true; // constructors and urgent counters retain precedence
            float FirstT2BankSeconds = 2.0f; // startup buffer; full package still needs sustained M/E funding
            int HarborSurveySeconds = 90; // keep an untouched site stable long enough for reconnaissance
            float ShoreSurveyCell = 320.0f;
            int ShoreSurveySeconds = 45;
            float AntiNukeBaseRadius = 480.0f;
            float AntiSubArcRadians = 2.4f; // shallow concave firing line, within underwater weapon range
            float AntiSubRangeFraction = 0.92f;
            float AntiSubFrigateRangeFraction = 0.82f; // Legion: 460 torpedo range, only 400 own sonar
            bool RespectCarrierControl = true; // yield attached drones to the game's carrier gadget
            bool HybridScoutAirResponse = true; // SEA scout/dedicated AA interception, all factions
            int ScoutPatrolSeconds = 120;
            float ScoutMaximumThreat = 0.1f;
            bool ScoutDiagnostics = false;
            float ScoutArrivalRadius = 96.0f;
            float ScoutRouteThreatWeight = 8.0f;
            float ScoutRouteSampleSpacing = 80.0f;
            float ScoutRouteMinimumDepth = 12.0f;
            int ScoutFailedSectorSeconds = 30;
            bool ScoutSurfaceRaids = false; // Keep dedicated scouts on separate shore surveys.
            int ScoutRaidMinimumShips = 3;
            int ScoutRaidSurveyReserve = 1; // continue discovering other yards during a raid
            float ScoutRaidRecruitRadius = 2400.0f;
            float ScoutRaidAssemblyRadius = 640.0f;
            float ScoutRaidRangeMargin = 96.0f;
            float ScoutRaidMinimumHealth = 0.75f;
            int ScoutRaidAssemblySeconds = 30;
            int ScoutRaidMaximumSeconds = 90;
            float ScoutRaidFiringRangeFraction = 0.9f;
            float ScoutRaidArcRadians = 1.0f;
            float ScoutRaidFormationSpacing = 72.0f;
            float ScoutRaidRepositionDistance = 96.0f;
            float NavalAAFormationSpacing = 320.0f; // capped by shortest AA range for overlapping coverage
            int NavalAAColumns = 6;
            float NavalAAInterceptSeconds = 12.0f;
            int NavalAAContactMemorySeconds = 8;
            float HybridSubCoverWeight = .5f; // T1 destroyer cost includes its surface gun; avoid valuing all of it as anti-sub
            float ThreatResponseRadius = 6000.0f;
            float AirCounterRatio = 0.7f;
            float SubCounterRatio = 1.2f;
            int FleetThreatMemorySeconds = 30; // retain a lost contact's cost, never its live hidden position
            int SubThreatMemorySeconds = 120;  // D-347: submarines vanish between sonar pings; keep their cost longer
            float UnknownSubContactMetal = 500.0f; // conservative sonar uncertainty, not a revealed UnitDef cost
            float FleetAirCoverShare = 0.06f;
            float FleetSubCoverShare = 0.3f;
            float SiegeFleetMetal = 4500.0f;
            float FleetAssemblySeconds = 120.0f;
            // D-300: SEA's own first-T2 gate. 30 M/s was never reached in a
            // natural Supreme game (plateau 26.4 M/s, T1 only for 25 min).
            float TechMinimumMetalIncome = 16.0f;
            float TechMinimumEnergyIncome = 400.0f; // SEA only; the shared ladder keeps MinimumEnergyIncomeForT2Shipyard
            // While the first T2 yard is wanted and unfinished, hold
            // discretionary T1 hulls (counters still answer threats) for at
            // most TechSaveMaxSeconds so the bank can fund the package.
            bool TechSave = true;
            float TechSaveMaxSeconds = 240.0f;
            float TechSaveContestRatio = 0.6f; // no save while enemy ships in our water exceed this share of ours
            int TechSaveTrickle = 3;           // every 3rd held factory ask still builds a T1 hull
            float CapitalAssistRadius = 900.0f;
            int CapitalAssistWorkers = 3;
            float HarborSearchRadius = 1200.0f;
            float ForwardHarborSearchRadius = 2400.0f; // crowded allied coasts can exhaust the opening-radius search
            float FirstPlannedHarborAdvance = 768.0f; // leave rear economy room when the native opening yard hugs shore/map edge
            float EnergyPerMetal = 25.0f;
            float ExitLength = 800.0f; // protected departure lane beyond densely packed support
            float ExitMargin = 48.0f;
            float HarborFogBuffer = 192.0f; // current allied LOS beyond the factory nose, admission only
            int CommanderHandoffTurrets = 4; // completed, in range; frames/reservations never count
            int CapacityObservationSeconds = 10;
            float CapacityHighMetal = 0.85f;
            int SupportParallelProjects = 4; // one per yard, shared live resource ledger
            bool CapacityUsesConversionEnergy = true; // subtract lost conversion metal when redirecting energy
            bool OverflowFactories = true;
            float OverflowGantryMetalReserve = 6000.0f; // bank remaining after the entire gantry cost
            float AmphibiousInterceptRadius = 5000.0f; // same connected sea; observed contacts only
            float AmphibiousInterceptMinimumMetal = 500.0f; // includes the 970-metal Marauder; not a tier proxy
            float HarborMaxThreat = 1.0f;
            int MaxProductionYards = 8;
            float TechPackageSeconds = 240.0f; // D-300: was 150 (package unaffordable below ~30 M/s)
            float TechPackageIncomeShare = 0.85f; // D-300: was 0.65; TechSave frees the T1 hull share
            float WorkforceHorizon = 45.0f;
            float EconomyIncomeShare = 0.45f;
            float ForwardMinimumGain = 800.0f;
            float ForwardStep = 900.0f;
            int ForwardStableSeconds = 30;
            int ForwardRecheckSeconds = 120;
            int MaxSupportPerBerth = 64; // finite useful local footprint, not a construction quota
            int ReservedSupportPerFactory = 64; // dense rear/sides; terrain can yield a smaller footprint
            bool SeaplanesAfterT2 = true;
            float SeaplaneMinimumMetalIncome = 80.0f; // minimum over the shared last-ten-second window
            float SeaplaneMinimumEnergyIncome = 1500.0f;
            float SeaplaneMetalReserve = 500.0f; // retained in addition to the full platform cost
            float SeaplaneEnergyReserve = 1000.0f;
            float NearbyMexRadius = 2400.0f; // fixed home harbor radius, not an ever-moving expansion centre
            bool ExpandMexClusters = true; // SEA only, independent of experimental economy/layouts
            float ExpansionMexRadius = 3600.0f; // follows the constructor; no home-radius or income ceiling
            float ExpansionClusterRadius = 600.0f;
            float ExpansionMaxThreat = 0.1f; // unarmed workers wait for navy to clear known weapon coverage
            float ExpansionThreatBuffer = 256.0f;
            float ExpansionEscortMetal = 600.0f; // nearby combat ships required toward the contested frontier
            int ExpansionRetrySeconds = 10;
            float ExpansionSurfaceIncome = 30.0f; // torpedoes first; funded surface towers later
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for SEA role
            /******************** SEA BASE SETTINGS ********************/
            // All settings applied to sea role at game start, logic can change throughout game
            float AllyRange = 2000.0f;

            /******************** SEA MILITARY QUOTAS ********************/
            // Scout unit cap for SEA role
            int MilitaryScoutCap = 3;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // SEA waves: shorter wait and a lower bar than the global default -
            // a navy that sits is a navy that loses the water.
            float MilitaryAttackWaitSeconds = 120.0f;
            float MilitaryAttackScale = 0.7f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 1.0f;
            float MilitaryRaidAvgPower = 5.0f;

            /******************** SEA ECONOMY SETTINGS ********************/
            // Prefer tidals over solars at sea; consider adding tidals if energy income is below this
            float TidalEnergyIncomeMinimum = 1200.0f; // tune per map; tidals vary
            // If energy is low, allow assisting the primary T1 sea worker
            float AssistPrimaryWorkerEnergyIncomeMinimum = 500.0f;

            // Early resurrection-sub policy toggle and tuning
            // When enabled, T1 shipyards may produce resurrection submarines early based on income scaling
            bool KeepFactoriesQueued = true; // D-211: recruit tasks retain shortage priority/energy control.
            bool EnableEarlyRezSub = true;
            float FleetMetalPerRezSub = 6000.0f;
            float RecoveryMetalLowFraction = 0.20f;
            float RecoveryMetalResumeFraction = 0.40f;
            float RecoverySearchRadius = 24000.0f;
            int RecoveryResurrectionGroupSize = 4;
            float RecoveryRepairCombatClearance = 600.0f;
            // Target = 1 + min(income / MetalIncomePerRezSub, fleet / FleetMetalPerRezSub), rounded down.
            float MetalIncomePerRezSub = 60.0f;

            // Consider energy storage "low" when current < storage * percent (SEA scope)
            float EnergyStorageLowPercent = 0.90f;

            // Minimum incomes for building advanced (T2) energy converter at sea
            float MinimumMetalIncomeForAdvConverter = 18.0f;
            float MinimumEnergyIncomeForAdvConverter = 1200.0f;

            // T1 Energy converter policy (SEA-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 40.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;

            // Fusion Reactor thresholds (SEA scope)
            float MinimumMetalIncomeForFUS = 30.0f; 
            float MinimumEnergyIncomeForFUS = 1200.0f;
            float MaxEnergyIncomeForFUS = 999999.0f;

            /******************** SEA BUILDER GUARD CAPS ********************/
            // Max number of workers assigned as guards to a single leader (primary or secondary) for SEA
            // Defaults mirror global caps; tune down to limit construction ships guarding.
            int BuilderMaxGuardsPerLeader = 2;
            // Max number of workers assigned as guards to a tactical SEA constructor
            int BuilderMaxGuardsPerTacticalLeader = 0;

            /******************** SEA NANO POLICY ********************/
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 20.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            /******************** SEA T2 SHIPYARD THRESHOLDS ********************/
            // Economy thresholds and caps for building an Advanced Shipyard (T2)
            // Require primary T1 shipyard to exist before attempting T2
            float MinimumMetalIncomeForT2Shipyard = 40.0f;
            float MinimumEnergyIncomeForT2Shipyard = 800.0f;
            float RequiredMetalCurrentForT2Shipyard = 800.0f;
            int MaxT2Shipyards = 1;

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system (replaces factory.json logic)
            // When enabled, uses threat-driven unit selection with tier scaling
            bool UseDynamicFactoryProduction = false;

            /******************** SEA FACTORY OUTPUT TARGETS ********************/
            // Maintain at least this many T2 destroyers; when below, enqueue in batches
            int MinT2DestroyerCount = 5;
            int T2DestroyerBatchSize = 5;

            /******************** COMMANDER FACTORY ASSIST (SEA) ********************/
            // Duration (in seconds) from game start during which the SEA commander
            // will prioritize guarding the primary T1 shipyard instead of falling
            // back to default builder behavior.
            int CommanderFactoryAssistDeadlineSeconds = 3 * 60; // default: first 2 minutes

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 shipyard. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks

            /******************** SEA DYNAMIC QUOTA SETTINGS ********************/
            // Enemy surface cost multiplier used to determine when SEA is underpowered.
            float DynamicQuotaEnemyCostThresholdMultiplier = 1.0f;

            // Underpowered quotas: used when SEA is behind in army power vs enemy surface cost.
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;

            // Delay (in seconds) before SEA starts applying dynamic quota adjustments.
            int DynamicQuotaDelaySeconds = 6 * 60;
        
        }
}
}
