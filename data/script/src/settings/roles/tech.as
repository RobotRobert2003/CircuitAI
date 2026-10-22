// TECH defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/tech/tech.as
namespace Global {
namespace RoleSettings {
namespace Tech {
            bool EcoFlakEnabled = false;
            int EcoFlakMinimum = 1, EcoFlakMaximum = 15;
            float EcoFlakCooldownSeconds = 30.f, EcoFlakBaseRadius = 1000.f;
            // D-306: loss recovery is asked only by idle builders, with bounded
            // native slot queries. Production refill uses the existing event path.
            bool EconomyRecoveryEnabled = true;
            int RecoverySlotBudget = 8;
            bool ContinuousGantryProduction = true;
            bool HeavyRushEnabled = true;
            // Inclusive one-time batch roll; an active rush retains its saved target.
            int HeavyRushCountMin = 3;
            int HeavyRushCountMax = 5;
            float HeavyRushMetalIncome = 40.0f;
            float HeavyRushBudgetSeconds = 90.0f;
            float HeavyRushIncomeShare = 0.70f;
            float HeavyRushEnergyMargin = 200.0f;
            float HeavyRushStableEnergy = 1000.0f;
            dictionary HeavyRushUnits = {{"armada", "armfboy"}, {"cortex", "corsumo"}, {"legion", "leginc"}};
            bool HeavyTransportPoolEnabled = true;
            float HeavyTransportAdditionalIncomeStart = 40.0f;
            float HeavyTransportMetalPerAdditional = 100.0f;
            float HeavyDeliveryArrivalRadius = 240.0f;
            float HeavyDeliveryDestinationMove = 192.0f;
            float HeavyDeliveryRouteRetrySeconds = 10.0f;
            bool HeavyDeliveryFrontEnabled = false;
            float HeavyDeliveryAirPadding = 192.0f;
            float HeavyDeliveryAirThreat = 0.5f;
            float HeavyDeliveryBlockedSeconds = 90.0f;
            float HeavyDeliveryFrontRadius = 128.0f;
            bool LocalGeothermalEnabled = true;
            float LocalGeothermalRadius = 1200.0f;
            float LocalGeothermalBudgetSeconds = 90.0f;
            float LocalGeothermalBootstrapEnergy = 300.0f;
            float LocalGeothermalIncomeFraction = 0.5f;
            // Role switch cadence (seconds)
            int MinAiSwitchTime = 400;
            int MaxAiSwitchTime = 500;

            // NukeLimit: maximum number of nukes allowed for TECH role
            int NukeLimit = 20;

            /******************** FLOATING METAL ********************/
            // Every gate in the T2 constructor ladder is income-based, so a
            // full bank on a modest income built nothing: the converter wanted
            // 1200 energy income, the fusions their own floors, the silo its
            // own - and the T1 constructors, whose only floating rule was "metal
            // over 1000 -> another nano", spammed construction turrets. This
            // ladder runs first while metal is floating and spends the bank.
            float FloatMetalCurrent = 2500.0f;     // or aiEconomyMgr.isMetalFull
            float FloatMetalIncome = 25.0f;        // floor, so a dead economy does not qualify
            float FloatConverterMinEnergyIncome = 800.0f;   // a converter needs energy to convert
            float FloatAFUSMetalCurrent = 6000.0f;          // advanced fusion above this, fusion below
            int FloatMaxNukeSilos = 1;             // silos this ladder will start (NukeLimit still caps)
            // Reserve-driven nanos beyond the income target (see ShouldBuildT1Nano).
            int NanoReserveSurplus = 2;

            /******************** ENERGY FOCUS ********************/
            // One energy structure at a time: before any energy rung, a
            // constructor assists the T1 energy structure already under
            // construction (Builder::EnqueueAssistEnergy), up to this many on
            // it. Build power on one solar finishes it sooner than two half
            // built, and the assist ends with the structure.
            bool EnergyFocusAssist = true;
            int EnergyFocusMaxAssists = 3;

            /******************** BASE LAYOUT ********************/
            // JSON permits the native mechanism for experimental profiles;
            // TECH is the only role that opts its AI instance in. Native owns
            // exact footprint geometry, atomic reservations and save/load.
            // Script owns candidate order and mature-module progression.
            // The experimental build system (D-066), one master switch. On:
            // TECH's own sequence (roles/tech_build.as) is the only source of
            // work, native's chooser and its start-factory and storage jobs
            // are silent for this instance, and native's site search never
            // spirals (planned slot, exact spot, or the free footprint nearest
            // the asked anchor within ExperimentalSearchRadius). Off: TECH runs
            // the stock ladder and stock placement like every other role.
            bool ExperimentalBuild = true;
            float ExperimentalBuildDirectRange = 1600.0f;   // D-064: the engine walks the last leg inside this
            float ExperimentalSearchRadius = 512.0f;        // D-066: how far from an anchor a site may be packed
            float ExpAssistRadius = 1500.0f;                // a constructor with nothing to build assists within this
            float ExpOrderRadius = 2000.0f;                 // native's queued defence/radar/repair orders are taken only within this of the base
            float ExpCommanderHomeRadius = 800.0f;          // the commander assists only within this of the base after the opening
            float ExpFirstLabRadius = 224.0f;               // the first (throwaway) T1 lab goes on the nearest footprint within this of the commander ...
            int FirstFactorySeconds = 300;                  // D-120: INV-050
            // D-121: cramped ground (no planned pair): structures packed this far from the nearest lab,
            // turrets near the labs: CrampedTurretsBase + one per CrampedTurretMetalStep of income, at most CrampedTurretsMax
            // D-121: the harbour (an island TECH, Global::Map::LandLocked): after this many advanced
            // fusions the economy moves to the water and the shipyards come; see roles/tech_harbour.as
            bool HarbourEnabled = true;
            int HarbourAfterAdvancedFusions = 2;
            int HarbourLatestSeconds = 900;                 // ... or this far in once an advanced lab has stood (the island's ground runs out first; played: raids from 17 minutes)
            // D-123: an air constructor with nothing else to do builds defences: the mex clusters' AA,
            // then a ring round the base toward the front (AirDefenceMax of each kind at most)
            int AirIdleAsks = 2;                            // D-123: asks in a row while idle before an air constructor takes defences instead
            /******************** LANES (D-127) ********************/
            // manager/lanes.as, doc/roles/tech-lanes.md; data/config/lanes.json overrides each
            bool LanesEnabled = true;                   // lanes/enabled
            int LaneAlternatives = 3;                   // lanes/alternatives
            float LaneMergeRadius = 450.0f;             // lanes/merge_radius
            float LaneThreatWeight = 1.0f;              // lanes/threat_weight
            float LaneRecalcSeconds = 180.0f;           // lanes/recalc_seconds
            float LaneRecalcShift = 1000.0f;            // lanes/recalc_shift
            float LaneRecalcMinSeconds = 60.0f;         // lanes/recalc_min_seconds: at most this often on a front move
            int LaneDrawSeconds = 30;                   // lanes/draw_seconds: owner: 30 s after the intro

            /******************** WEAPON CLUSTERS (D-126) ********************/
            // TECH's weapon clusters (roles/tech_weapons.as, doc/roles/tech-weapon-clusters.md).
            // These are the defaults; data/config/weapons.json (and a profile's own
            // weapons.json) overrides each at game start (TechWeapons::LoadSettings),
            // the JSON path in the comment.
            bool WeaponClustersEnabled = true;          // weapons/enabled
            float WeaponStartMetalIncome = 200.0f;      // weapons/start_metal_income: owner: no weapon cluster before +200 metal
            float WeaponBudgetShare = 0.25f;            // weapons/budget/share: of metal income, into weapon clusters
            float WeaponBudgetShareAttacked = 0.40f;    // weapons/budget/share_attacked: while the base area is being fought over
            float WeaponBudgetWindowSeconds = 60.0f;    // weapons/budget/window_seconds: the budget saves up at most this many seconds of share
            float WeaponAttackedHeat = 30.0f;           // weapons/budget/attacked_heat: combat heat within WeaponBaseRadius that counts as under attack
            float WeaponBaseRadius = 2500.0f;           // weapons/budget/base_radius
            float WeaponWallFrontRadius = 1100.0f;      // walls only near the selected fighting front
            float WeaponGroundFrontRadius = 1800.0f;    // short-range clusters must support that front
            int WeaponArmadaEmpCount = 1;
            int WeaponCortexTacticalCount = 1;
            int WeaponLegionPerditionCount = 3;
            float WeaponSpecialSpacing = 240.0f;
            float WeaponGeoClusterRadius = 1600.0f;
            float WeaponLaneFrontReserve = 512.0f;     // stand this far behind the selected lane's observed front
            float WeaponLaneSideOffset = 256.0f;       // keep cluster centre beside, never on, the lane
            int WeaponMaxConcurrent = 4;                // weapons/budget/max_concurrent: weapon orders out at once (the super cannon's escort apart)
            // income gates per cluster kind (metal income, 10 s minimum)
            float WeaponKillMinIncome = 200.0f;         // weapons/gates/kill_zone
            float WeaponAirMinIncome = 200.0f;          // weapons/gates/air_defence
            float WeaponCoastMinIncome = 250.0f;        // weapons/gates/coast
            float WeaponArtyMinIncome = 300.0f;         // weapons/gates/artillery
            float WeaponLrpcMinIncome = 350.0f;         // weapons/gates/long_range
            float SuperMinMetalIncome = 500.0f;         // weapons/super/min_metal_income: owner: at least +500 to start a super cannon
            float SuperIdealMetalIncome = 1000.0f;      // weapons/super/ideal_metal_income: owner: ideally over +1000 (below it, only with a high need)
            float SuperMinNeed = 1.5f;                  // weapons/super/min_need: the need a super cannon needs between the two incomes
            float SuperEnergySpareFactor = 1.0f;        // weapons/super/energy_spare_factor: spare energy income x the cannon's sustained draw
            // how many of each cluster kind, and each cluster's shape
            int WeaponMaxKill = 4;                      // weapons/max/kill_zone
            int WeaponMaxAir = 4;                       // weapons/max/air_defence
            int WeaponMaxCoast = 4;                     // weapons/max/coast
            int WeaponMaxArty = 3;                      // weapons/max/artillery
            int WeaponMaxLrpc = 3;                      // weapons/max/long_range
            int WeaponMaxSuper = 1;                     // weapons/max/super
            int WeaponNanoPerCluster = 4;               // weapons/cluster/nanos: owner: at least 4 construction turrets per cluster
            float WeaponWorkRadius = 8000.0f;           // weapons/cluster/work_radius: a land constructor takes cluster work within this
            float WeaponCriticalSpacing = 1280.0f;      // weapons/cluster/critical_spacing: nuke AoE between critical structures
            float WeaponAirSpacing = 260.0f;            // weapons/cluster/air_spacing: AA pieces apart (1.5 x a bomb's AoE)
            // super cannon (owner, W9)
            int SuperStorageMin = 2;                    // weapons/super/storage_min: advanced energy storages at least
            float SuperStorageMargin = 1.1f;            // weapons/super/storage_margin: storage holds a full shot x this
            int SuperFlakCount = 6;                     // weapons/super/flak: dense forward flak
            int SuperLongRangeAACount = 2;              // weapons/super/long_range_aa
            int SuperDeflectorCount = 2;                // weapons/super/deflectors
            int SuperAntiNukeCount = 1;                 // weapons/super/anti_nukes (2 once an enemy silo is seen)
            int SuperNanoCount = 8;                     // weapons/super/nanos
            int SuperRadarCount = 2;                    // weapons/super/radars
            float SuperBandMin = 0.2f;                  // weapons/super/band_min: of the cannon's range back from the active combat zone
            float SuperBandMax = 0.4f;                  // weapons/super/band_max
            float SuperEscortRadius = 900.0f;           // weapons/super/escort_radius
            int SuperEscortSeconds = 300;               // weapons/super/escort_seconds: INV-058's grace
            // long range (LRPCs share the band, owner)
            float WeaponLrpcBandMin = 0.2f;             // weapons/long_range/band_min
            float WeaponLrpcBandMax = 0.4f;             // weapons/long_range/band_max
            // analysis
            float WeaponReplanSeconds = 60.0f;          // weapons/analysis/replan_seconds: sites re-found and re-ranked
            float WeaponAnalyseSeconds = 600.0f;        // weapons/analysis/analyse_seconds: routes and beaches recomputed
            int WeaponRouteAlternatives = 3;            // weapons/analysis/route_alternatives
            float WeaponChokeHalfWidth = 480.0f;        // weapons/analysis/choke_half_width
            float WeaponChokeMerge = 900.0f;            // weapons/analysis/choke_merge
            float WeaponKillShareMin = 0.2f;            // weapons/analysis/kill_share_min: kill zones between these shares of a route
            float WeaponKillShareMax = 0.6f;            // weapons/analysis/kill_share_max
            float WeaponCombatMinHeat = 5.0f;           // weapons/analysis/combat_min_heat: an active combat zone
            float WeaponCombatHalfLife = 180.0f;        // weapons/analysis/combat_half_life
            float WeaponAirHalfLife = 300.0f;           // weapons/analysis/air_half_life
            float WeaponCoastRadius = 3500.0f;          // weapons/analysis/coast_radius: beaches this close to the base
            float WeaponEnemyCoastRadius = 2500.0f;     // weapons/analysis/enemy_coast_radius: water this close to an enemy start is hostile
            int HarbourMaxT2Shipyards = 1;
            int HarbourYardSeconds = 480;                   // INV-051: the advanced shipyard framed this soon after the harbour begins
            int HarbourHoverConstructors = 3;               // the hover plant's constructors: they float out and build the advanced shipyard
            float HarbourYardSearch = 1200.0f;              // the advanced shipyard's site search around the hover plant (deep water)
            int HarbourT1SeaConstructors = 3;
            int HarbourT2SeaConstructors = 4;
            int HarbourTurrets = 10;                        // floating construction turrets at the yards
            float HarbourTurretRadius = 320.0f;
            float HarbourRadius = 900.0f;                   // the sea economy is packed this far from the yards
            float HarbourEnergyLowShare = 0.3f;             // energy under this share of storage: energy first
            float HarbourConverterEnergyShare = 0.6f;       // construction subs add floating advanced converters while energy is over this share, else a naval fusion
            float HarbourTidalUntilEnergy = 1500.0f;        // T1 construction ships add tidals while energy income is under this
            float HarbourCommanderMinEnergy = 150.0f;       // ... and only with this much energy income
            int HarbourCommanderConverters = 30;            // before the harbour: the commander's floating converters while energy floats, at most
            float HarbourCommanderReach = 1200.0f;          // ... placed within this of it (the nearest deep-enough water)
            float CrampedPlaceRadius = 640.0f;
            float CrampedReachElmos = 128.0f;              // D-121: a lab site counts as reachable when a land constructor gets this close
            float CrampedTurretRadius = 256.0f;
            int CrampedTurretsBase = 2;
            float CrampedTurretMetalStep = 10.0f;
            int CrampedTurretsMax = 16;
            float CrampedFirstLabRadius = 800.0f;          // D-120: with no planned pair (cramped ground) the first lab searches this far from the commander
            float ExpFirstLabClearance = 32.0f;             // ... but its footprint edge stays at least this far from the commander's position
            // D-114 (owner's rules): land factories move toward the front in front factory clusters
            float FrontMinShare = 0.2f;                     // D-114: a front cluster stands at least this share of the way from the base toward the front
            float FrontMaxShare = 0.8f;                     // D-114: and no further than this
            float FrontShareStep = 0.04f;                   // D-114: the search steps this share toward the front at a time
            int FrontLateralTries = 6;                      // D-114: positions tried each side of the line at each step
            float FrontMinFlat = 0.85f;                     // D-114: this share of the cluster's ground flat (LayoutBoxMaxSlope)
            float FrontRoomyShare = 0.9f;                   // D-114: first pass: this share of the ground round the cluster buildable (away from other buildings)
            int FrontClearCells = 4;                        // D-114: the room kept round a cluster in the first pass
            int FrontT1TurretCols = 2;                      // D-114: a T1 lab's turret block: 2 x 1
            int FrontT1TurretRows = 1;
            int FrontT2TurretCols = 2;                      // D-114: a T2 lab's: 2 x 2
            int FrontT2TurretRows = 2;
            int FrontT3TurretCols = 10;                     // D-119 (owner): a gantry's block holds up to 50 turrets: 10 x 5 (smaller blocks where the ground is smaller)
            int FrontT3TurretRows = 5;
            // D-281: deterministic gantry admission and missing-worker recovery.
            bool GantryClusterRecoveryEnabled = true;
            bool EarlyGantryEnabled = false; // experimental_balanced opts in
            int EarlyGantryIncomeWindowSeconds = 10;
            int EarlyGantryMaximumSampleGapSeconds = 2;
            float EarlyGantryMetalIncome = 200.0f;
            int EarlyGantryAttemptSeconds = 180;
            float GantryFundingSeconds = 180.0f;
            float GantryFundingShare = 0.70f;
            float GantryEnergyReserve = 200.0f;
            float GantryMinimumBuilderPower = 100.0f;
            float GantryMaximumSurfaceThreat = 1.0f;
            float GantryExitProbeDistance = 320.0f;
            int GantryTurretWaitSeconds = 90;
            int GantryAssistSeconds = 60;
            int GantryMaximumTaskBuilders = 2;
            int GantryLogIntervalSeconds = 30;
            // D-287 (owner): Marauder-class units (armmar, corshiva, legjav) only in
            // the early T3 window. Late = game time OR 10 s minimum metal income,
            // latched once (never un-latches, persisted). Late gantries build the
            // terrain's heavy: the land heavy on a land map, the amphibious heavy
            // when the start is land-locked or an assault beach front exists.
            bool HeavyChoiceEnabled = true;
            int HeavyLateMinutes = 20;
            float HeavyLateMetalIncome = 400.0f;
            int HeavyAmphibiousMinBeaches = 1;          // assault beach fronts (StrategicSites) that make a map "amphibious"
            int LateMarauderMassBatch = 0;              // 0 = no late Marauders; N = one late batch of N Marauders on an amphibious map (owner's "very large numbers" exception, off)
            string HeavyLandArmada = "armthor";
            string HeavyAmphArmada = "armbanth";
            string HeavyLandCortex = "corkorg";         // owner default; "corjugg" (Behemoth: land only, very slow) is the alternative
            string HeavyAmphCortex = "corkorg";
            string HeavyLandLegion = "legerailtank";
            string HeavyAmphLegion = "legeheatraymech";
            // D-288 (owner): one land gantry per GantryScaleMetalStep of 10 s minimum
            // metal income (floor(income / step), capped at GantryScaleMax). The target
            // is a persisted high-water mark (a dip never lowers it); a new order also
            // needs income >= (have + 1) x step x GantryScaleDropShare right now.
            bool GantryScaleEnabled = true;
            float GantryScaleMetalStep = 500.0f;
            float GantryScaleDropShare = 0.80f;
            float GantryScaleEnergyFloor = 0.0f;        // optional absolute E/s floor (0 = metal only, the owner's rule)
            int GantryScaleMax = 6;
            int GantryScaleGraceSeconds = 300;          // INV-199: due this long without progress (cooldown 120 s + turrets + order)
            int FrontT3TurretsFirst = 10;                  // D-119: the gantry is ordered once this many of its turrets stand; the rest keep filling
            int FrontReclaimAtCount = 3;                    // D-114: this many land factories on the map retire the base's land factories
            float FrontBaseRadius = 1200.0f;                // D-114: a land factory within this of the base centre is the base's
            int FrontBaseReclaimSeconds = 240;              // D-114: INV-044: a base land factory still standing this long after the count is reached
            int FrontRowMaxLabs = 4;                        // D-117: T1 spam labs side by side in a row of up to this many
            int FrontRowGapCells = 3;                       // D-119: cells between two labs of a row: side by side, clear of the neighbour's blocker yard (block_map.json fac_bot: yard 6 = 3 cells each side; closer was always refused)
            int FrontT3LaneCells = 6;                       // D-117: the lane kept open beside every spam row: the largest T3 movement classes (HBOT7, HTANK7) are 7 map squares = 3.5 cells wide, plus room
            float FrontLaneMinFlat = 0.9f;                  // D-117: a lane counts as passable with this share of its ground flat (LayoutBoxMaxSlope) and free
            int FrontClusterStallSeconds = 300;             // D-114: a front factory order with no frame this long gives its cluster up
            int FrontClusterOpenSeconds = 600;              // D-114: INV-046: an open T2 or T3 front cluster without its factory this long after it was planned
            // D-109 (owner's rules): the land constructors leave the base once the air constructors carry it
            int T1AirReleaseAbove = 5;                      // D-109: more than this many T1 air constructors release the T1 land constructors
            int T1AirConstructorTarget = 6;                 // D-109: the T1 air plant keeps this many T1 air constructors
            float ForwardHomeRadius = 900.0f;               // D-109: a construction beyond this from the base centre is a forward job (dropped on a recall)
            float MexClusterRadius = 600.0f;                // D-109: a mex within this of a cluster's centre joins the cluster
            float MexDefenceBaseClear = 900.0f;             // D-109: mex clusters nearer the base centre are the eco layout's ground, not defended here
            float MexDefenceRadius = 400.0f;                // D-109: a defence within this of a cluster's centre counts for it
            float MexDefenceShake = 160.0f;                 // D-109: native picks the defence's site within this of the cluster's centre
            int ForwardOrderHoldSeconds = 120;              // D-109: an order at one place is not repeated within this
            int PlannedFactoryClustersPerTier = 2;          // D-153: future ground only, per T1/T2/gantry
            int SpamLabGapCells = 2;                        // D-109, D-114: cells between side-by-side search positions of a front cluster (a lane each)
            float SpamClusterRadius = 600.0f;               // D-109: forward constructors assist what goes up within this of the spam cluster
            int SpamPadsMax = 2;                            // D-109: small 2x2 forward turret pads at the lab row's ends
            float ConverterStarveEnergyShare = 0.5f;        // D-107: the energy bank under this share of storage (or stalling) means the converters cannot stay on (BAR's conversion level is 75% by default)
            // D-175: shared by ALL roles; keep the Tech namespace for existing overrides.
            float TeamShareMetalAbove = 0.95f;              // D-106: our metal bank over this share of storage triggers the team economy check and a donation
            float TeamShareMetalBudget = 0.20f;             // D-106: at most this share of our metal storage is given per donation, the lowest-filled teammate first
            float TeamShareCheckSeconds = 5.0f;             // D-106: a donation at most this often (the engine's share command settles each slow update)
            float TeamShareMinAmount = 25.0f;               // D-106: smaller gifts are not sent
            float AfusFundedShare = 0.85f;                  // D-105: the advanced lab is not reclaimed when bank + income x the advanced fusion's remaining build time covers this share of its cost
            float AfusBuildTime = 330000.0f;                // D-105: the advanced fusion's buildtime (corafus 329200, armafus 312500, legafus 340000 in BAR's unitdefs)
            float AfusProjectionRadius = 600.0f;            // D-105: build power within this of the advanced fusion frame counts for its finish time
            float ReclaimOtherPowerRadius = 600.0f;         // D-105: a T2 constructor reclaims only when no other build power is within this of the target
            float LabEcoOnlineMetalIncome = 200.0f;         // D-102: the economy is online: no lab is reclaimed for its metal, T1 labs are for spam, the advanced lab is rebuilt
            int LabRebuildMinT1Cons = 3;                    // D-102: below LabEcoOnlineMetalIncome, this many T1 constructors and no lab is rebuilt
            float SpamLabMetalStep = 100.0f;                // D-105: one more spam lab per this much metal income over LabEcoOnlineMetalIncome
            int SpamLabsMax = 6;                            // D-105: the spam labs' ceiling
            int ExpSpamLabs = 1;                            // T1 labs kept for the spam economy once its gate is open and the advanced lab stands
            bool ExpTurretNearLab = true;                   // D-069: the next box turret slot is the one nearest a standing lab, not the one nearest the pair's centre
            float ExpLabBuildPowerReach = 260.0f;           // D-069: elmos within which static build power (turrets) counts for a lab site: a nano's build distance plus the lab's radius
            string EndgamePlan = "auto";                   // D-080: nuke | t2rush | t3rush | lrpc | auto (deterministic from the team id) - what follows the rush objective
            float PlanCombatGate = 200.0f;                  // D-080: no mobile combat unit under this metal income (every plan)
            float PlanT3RushCombatGate = 500.0f;            // D-080: ... the t3rush plan's gate
            float PlanLrpcMetal = 300.0f;                   // D-080: the lrpc plan's income before the long-range cannon
            float PlanAirConstructorsFromMetal = 200.0f;    // D-080: from this income T2 construction aircraft are the mobile build power
            float PlanAirConstructorPerMetal = 40.0f;       // D-080: one T2 air constructor per this much income ...
            int PlanMaxAirConstructors = 12;                // D-080: ... at most this many
            int LadderParallelAfus = 2;                     // D-080: advanced fusions under construction at once on the ladder while the metal bank is full
            float InvariantLabReachSeconds = 90.0f;         // D-085 INV-016 / D-088 INV-017 patience         // D-085: INV-016 - the advanced lab standing this long with no static build power within ExpLabBuildPowerReach is a violation
            float InvariantDearOrderSeconds = 45.0f;        // D-084: INV-015 - a dear chain order with no frame this long is a violation
            float InvariantLadderFloatSeconds = 60.0f;      // D-080: INV-011 - the metal bank full this long with an income step unmet is a violation
            string RushObjective = "auto";                  // D-229: auto uses nuke for the existing nuke plan, otherwise afus
            int NukeRushMexUpgrades = 4;                    // bounded investment before the first fusion/silo, not every distant mex
            int NukeRushMexBeforeFusion = 3;                // income base before committing the technology builder to fusion
            float NukeRushBootstrapEnergy = 280.0f;         // expected T1 generation before upgrades; wind/bonus adjusted
            float NukeRushSiloEnergy = 320.0f;              // completed T1 generation before silo, in addition to the completed fusion
            float NukeRushStorageLowPercent = 0.10f;       // refund temporary metal storage before a construction stall
            float NukeRushStorageReclaimMove = 64.0f;     // short local approach beyond build distance + target model radius
            int NukeRushT1Constructors = 3;                 // expansion, local economy and technology construction
            int NukeRushT2Constructors = 2;                 // ordinary constructor scaling resumes when the silo stands
            int NukeRushTurrets = 5;                        // concentrated build power for fusion and silo
            int NukeRushFusionTurrets = 2;                  // start fusion while T1 workers finish the remaining support
            int NukeRushEnergyStores = 2;                   // bank fusion surplus during silo construction for stockpile wind lulls
            int NukeRushStockpileBudgetSeconds = 300;       // spare-energy construction until first missile stocks; bounded recovery if silo stalls
            int NukeRushScouts = 2;                         // earn enemy-base vision before the first missile is ready
            int NukeRushScoutSeconds = 20 * 60;             // replenish cheap reconnaissance during the first-shot window
            // D-070: the commander's home mexes are the opening's (OpeningMexRadius / OpeningMexCap: the
            // spots within 700 of the start, at most 3 - three on Supreme Isthmus, one or none elsewhere),
            // the lab follows at once, and the constructors claim the rest within ChainMexFarRadius
            float ChainMexFarRadius = 2500.0f;
            float ChainMohoRadius = 2500.0f;                // D-100: the moho step upgrades every mex of ours within this of the start (0: the recipe's count only)
            int ChainMaxMexes = 6;                          // D-070: mexes the chain claims in all
            // D-070: energy by the map's wind, deterministically. Expected turbine output is the average of the
            // map's min and max wind (capped at a turbine's 25). Turbines are chosen when their metal per E/s is
            // under the solar's by ChainWindMargin and the max wind reaches ChainWindMaxMin (a lull must be worth
            // riding out). The first energy structure is a solar when the current wind is under ChainWindBootstrap.
            float ChainWindMargin = 1.25f;
            float ChainWindMaxMin = 12.0f;
            float ChainWindBootstrap = 5.0f;
            float ChainAssistRadius = 4000.0f;
            float ChainParallelCostM = 400.0f;
            float ChainStepStallSeconds = 120.0f;           // D-070: a chain step with no progress for this long is skipped (an unreachable frame must not end the rush)              // D-070: structures cheaper than this (metal) are built one per builder in parallel; dearer ones get every builder on one frame              // D-070: every builder inside this joins the current step's frame
            float ChainNearFrameRadius = 600.0f;            // D-075: a chain frame of a cheap step within this of the builder is finished before anything else
            float PowerTurretBankFactor = 1.5f;             // D-075: ... and the bank holds this many turret costs
            float PowerBuildPowerPerMetal = 20.0f;          // D-075: the rule stops at this much static build power (workertime) per metal/s of income (played: 45 turrets in three minutes without it)
            // D-097: how many construction turrets go up at once (Layout::TurretsAllowed):
            // as many as the nearby build power finishes within PowerTurretBatchSeconds
            // and the bank plus income pays for in full; never under 1, never over
            // PowerTurretsMax; the other builders assist the turret going up
            float PowerTurretBatchSeconds = 20.0f;
            int PowerTurretsMax = 8;
            float PowerTurretBuildTime = 5300.0f;           // the T1 construction turret's buildtime (cornanotc, armnanotc, legnanotc: 5300 in BAR's unitdefs)
            float InvariantNoRoomSeconds = 120.0f;          // D-099: INV-020's patience - the layout refusing economy structures for lack of room     // D-097: INV-019's patience
            float InvariantFrameRadius = 320.0f;            // D-076: INV-002 - build power counted within this of a frame
            float InvariantFrameSeconds = 60.0f;            // D-076: INV-002 - a frame with no build power for this long is abandoned
            float InvariantFloatPercent = 0.9f;             // D-076: INV-004 - the metal bank at this share of storage is floating
            float InvariantFloatSeconds = 60.0f;            // D-076: INV-004 - ... for this long while a structure is under construction with build power short
            bool ExpTurretCentreOut = true;                // D-077: turrets start at the box centre and grow outward as one connected cluster (NextSlotConnected); off = D-069 nearest-lab
            float ReclaimT1EnergyMargin = 1.25f;            // D-077: winds and solars are reclaimed once a fusion stands and energy income without them covers the pull by this
            float ReclaimAdvSolarMargin = 1.5f;             // D-077: advanced solars once income without every T1/adv source covers the pull by this; an advanced fusion reclaims all
            float ReclaimEnergyRadius = 2500.0f;            // D-077: energy structures within this of the base centre, nearest first
            int ReclaimEnergyConcurrent = 4;                // D-077: energy reclaims in flight at once
            float InvariantReclaimSeconds = 240.0f;         // D-077: INV-006 - T1 or advanced-solar energy standing this long after an advanced fusion is a violation
            float ReclaimTurretMargin = 48.0f;              // D-078: a turret within its build distance plus this of a reclaim target joins the reclaim at once
            float InvariantReclaimJoinSeconds = 10.0f;      // D-078: INV-008 - a turret in range of a reclaim of ours off it this long is a violation
            float InvariantT2ReclaimSeconds = 15.0f;        // D-078: INV-007 - an advanced lab not retiring this long into an advanced fusion with bank room is a violation
            // D-290 (owner): one reclaim gate, TechReclaim::Allowed. A reclaim of our own structure is
            // ordered (and kept running) only while current + inflow + refund <= (storage - the target's
            // own storage) x ReclaimBankHeadroom; energy storage is never reclaimed (script and native).
            float ReclaimBankHeadroom = 0.95f;              // D-290: share of the post-reclaim metal storage the refund must fit under
            float ReclaimProjectionSeconds = 0.0f;          // D-290: seconds of net metal inflow (income - pull) added to the bank before the refund lands; 0 = the bank now (the 1 s pause check covers inflow while reclaiming)
            bool ReclaimProtectEnergyStorage = true;        // D-290 (owner): TECH marks every energy storage def reclaim-protected natively (the watchdog repairs, never reclaims, such a frame)
            float InvariantReclaimOverflowSeconds = 5.0f;   // D-290: INV-209 - a script reclaim of ours still running this long while its refund cannot fit the bank is a violation
            float ReclaimDeferredStaleSeconds = 30.0f;      // D-290: a gate deferral counts as current for this long after the last ask; INV-006 and INV-044 hold their clocks while one is current
            // D-289 (owner): construction turrets have one ladder: high-priority frames in reach, any
            // frame in reach, then assisting a producing (non-spam) factory in reach, then wait.
            float TurretFactoryReachMargin = 24.0f;         // D-289: a turret within its build distance plus this of a factory's centre assists it (a guard repairs curBuild at the yard: Recoil BuilderCAI.cpp:931)
            int TurretFactoryGuardSeconds = 10;             // D-289: builder-side factory guard timeout; the ladder is re-run after it, so a new frame in reach pre-empts within this
            float TurretFactoryMinBankShare = 0.05f;        // D-289: under this share of metal storage, with a dear frame of ours up, turrets do not feed unit production
            bool TurretFactoryInNukeFunding = false;        // D-289: during the D-229 silo funding window turrets do not feed unit production
            bool TurretFactorySkipOnEnergyStall = false;    // D-289: true = no factory assist while energy stalls (off: the owner's fallback; native repair pauses on empty energy)
            float TurretFrameMaxRadius = 200.0f;            // D-289: a bound on any frame's model radius: one FindUnfinishedNear at build distance plus this pre-checks the ordered frame scans
            float InvariantTurretIdleSeconds = 20.0f;       // D-289: INV-200 - a turret waiting this long while a producing factory it may assist stands in reach is a violation
            float ChainEnergyFloatMax = 300.0f;             // D-079: ... or the bank at EcoConvertEnergyPercent with income over the pull by this now (played: the advanced fusion ordered 15 s after the fusion at +1,291)
            float ChainEnergyFloatRise = 100.0f;            // D-079: ... or the bank above half of storage, up by this over ChainEnergyFloatSeconds, with income over the pull by ChainEnergyFloatMax (the moment a fusion completes)
            int ConverterParallel = 3;                      // D-079: converters queued at once while energy floats (one at a time otherwise); the pull-inflated surplus is replaced by half the income while floating
            float ChainEnergyFloatSeconds = 15.0f;          // D-079: the energy bank at EcoConvertEnergyPercent of storage for this long = energy floats: no energy structure is ordered, converters first (the pull is inflated by the build in progress, so the bank is read, not the pull)
            float InvariantFloatOrderSeconds = 90.0f;        // D-079: INV-009 - an energy frame appearing after the bank has been full this long was ordered while floating
            float PowerAheadSeconds = 15.0f;                // D-075: the metal bank at InvariantFloatPercent of storage for this long, or risen by PowerAheadRise over it = income above spending
            float PowerAheadRise = 30.0f;                   // D-075: ... the rise over PowerAheadSeconds that counts as the bank rising
            float ExpCombatMetalIncome = 200.0f;            // D-068: under this 10 s metal income TECH's labs make no combat unit (rush bots stay capped, no scout/fast-bot batches); 0 = never
            float EcoMexExpandRadius = 2500.0f;             // constructors expand to the nearest open spot within this ...
            float EcoMexExpandUntilIncome = 60.0f;          // ... while metal income is under this
            bool LayoutEnabled = true;                      // the planned base (needs ExperimentalBuild)
            int CompactEcoColumns = 2;
            int CompactEcoRows = 2;
            int CompactEcoGapCells = 1;                     // leave room for adjacent footprint levelling
            int CompactEcoMaxClusters = 24;
            int CompactEcoSearchRings = 16;                  // resumable square spiral, 1024-elmo radius
            float CompactEcoSearchStep = 64.0f;
            int CompactEcoSearchBudget = 128;                // individual footprints per growth ask
            float CompactEcoTurretSpread = 128.0f;           // individual additions, up to columns * rows
            float CompactEcoRetrySeconds = 60.0f;            // failed searches only
            int CompactEcoPackingAttempts = 8;              // expensive building fits per search
            float LayoutForwardRetrySeconds = 30.0f;
            float LayoutForwardBlockedRetrySeconds = 300.0f;
            int CrampedSupportColumns = 2;
            int CrampedSupportRows = 1;
            int LayoutOverflowModules = 8;
            int LayoutOverflowRings = 8;
            float LayoutOverflowStepElmos = 128.0f;
            float LayoutOverflowRetrySeconds = 60.0f;
            // The opening (D-063): the OpeningMexCap reachable mexes nearest
            // the start within this radius, taken nearest the commander first,
            // before any other structure (cap 0 = all of them). Played: the
            // fourth spot was 944 elmos out toward an ally, and the third
            // already drains the 1,000 E bank; three, then the next step.
            // Native's start factory is held until then, at most
            // OpeningMaxSeconds, never past the commander.
            // 700: the home cluster. Played on Supreme the third spot is 947
            // elmos out toward an ally and the commander walked there; with
            // 700 the opening takes the two home spots and the lab follows.
            float OpeningMexRadius = 700.0f;
            int OpeningMexCap = 3;
            int OpeningMaxSeconds = 240;
            // After the opening the commander stays home: native mex defaults
            // farther than this from the start are left to the constructors
            // (played: the ladder's mex-first rule sent it off to a fourth mex).
            int LayoutFactorySideStepCells = 4;
            int LayoutFactorySideTries = 4;
            int LayoutFactoryForwardStepCells = 4;
            int LayoutFactoryForwardTries = 2;
            // The turret box (D-063): the rectangle behind the factory pair
            // that holds the planned construction turrets (invisible until
            // built) and every economy structure, packed on the cells nearest
            // a turret. Searched largest first over rear and side offsets; a
            // size is taken when its best ground clears LayoutBoxMinScore.
            int LayoutBoxAcrossCells = 40;           // 640 elmos
            int LayoutBoxDepthCells = 44;            // 704 elmos: four turret rows at a 14-cell pitch
            int LayoutBoxShrinkCells = 8;
            int LayoutBoxMinAcrossCells = 24;
            int LayoutBoxMinDepthCells = 16;         // D-081: three touching turret rows (9 cells) and what is left is the shelf (played: 21 fit no box on Supreme Isthmus)
            int LayoutBoxSideStepCells = 6;          // D-082: wider side search, so the block can move off a mountain (6 x 6 = 36 cells = 576 elmos either way)
            int LayoutBoxSideTries = 8;              // D-082: up to 48 cells (768 elmos) either way, enough to stand beside the pair
            int LayoutBoxForwardTries = 4;           // D-082: box candidates level with or ahead of the pair's rear line (negative rear), only beside the pair
            int LayoutBoxBesideClearCells = 4;       // D-082: cells between the pair's footprints and a box standing beside them
            float LayoutHaloMin = 0.70f;             // D-087: a box whose halo scores this is good enough; among good enough the nearest the home mexes wins (played: 86 % halo 690 elmos away beat 75 % next to the mexes)
            int LayoutBoxRearStepCells = 4;
            int LayoutBoxRearTries = 3;
            float LayoutBoxMinScore = 0.75f;         // flat fraction x buildable fraction
            float LayoutBoxMaxSlope = 0.02f;         // engine slope (1 - cos), about 11 degrees
            bool LayoutSeedAtHomeMexes = true;       // D-086: the block, the first turret and the advanced lab are anchored on the centre of the home mex spots (where the builders are after the opening), not the start position
            float LayoutLabServedReach = 300.0f;
            int LayoutLabMinSlots = 4;               // D-090: 8 found no site on Supreme (best 7)               // D-088: a lab site needs this many turret slots within reach (weighted) to be considered
            int LayoutLabFrontGapCells = 3;          // D-096: the advanced lab's front-line site may stand this many cells ahead of turret row 0 (the zone's edge, a rock)
            int LayoutAfusSetSize = 3;               // D-101: advanced fusions per set: the first flush against a turret, the rest lined up away from it
            int LayoutConvSetSize = 5;               // D-101: advanced converters per set, the same way
            int LayoutSetMaximumTurretGapCells = 0;  // first member touches a supporting turret footprint
            float LayoutSetHoldSeconds = 300.0f;     // D-101: a set's unserved slots are released when nothing asked for its def this long
            float LayoutFrontMinCost = 1500.0f;      // D-096: a seen enemy group counts as a front at this metal cost; until one is seen the front is the map centre
            float LayoutLabFlushElmos = 160.0f;      // D-088: INV-017 - the nearest turret to the advanced lab, centre to centre, flush like the pair's nanos at the T1 lab     // D-086: the advanced lab keeps its planned footprint only if a standing turret is within this; else it is packed nearest a standing turret
            bool LayoutBoxAtStart = true;            // D-083: the main cluster is planned around the start position (the home mexes), not behind the factory pair
            int LayoutBoxPairClearCells = 6;         // D-083: a candidate block whose rectangle plus this margin holds a pair factory slot is skipped
            int LayoutHaloCells = 18;                // D-082: the halo of packing ground on both sides and behind the turret block (288 elmos, inside a turret's 400 reach); the box is scored and its zone reserved with it
            float InvariantReachElmos = 450.0f;      // D-082: INV-014 - a packed economy structure further than this from every turret slot is a violation
            int LayoutBoxMaxExtra = 4;               // D-072: boxes grown behind the first when it is full (each with its own turret rows)
            int LayoutBoxShelfCells = 12;            // building depth between turret rows: 192 elmos, inside a turret's 400 reach
            int LayoutBoxNanoRows = 4;               // D-081: four turret rows per cluster (a MapConfig may override)
            bool LayoutTurretBlock = true;           // D-081: the rows touch (a solid block filled across every row), the shelf for other structures behind it; off = a shelf between rows
            int LayoutBoxMinRows = 3;                // D-081: a cluster with fewer rows than this is not planned (INV-012)
            int LayoutForwardGapCells = 8;           // D-081: clear cells between the main cluster's front and the forward cluster
            int LayoutForwardStepCells = 12;         // D-081: each re-plan of the forward cluster moves it this much further forward
            int LayoutForwardTries = 3;              // D-081: re-plans of the forward cluster when an ally takes its ground
            float InvariantForwardSeconds = 120.0f;  // D-081: INV-013 - a main cluster without a forward cluster this long is a violation
            float LayoutConverterNanoGap = 0.0f;     // elmos an advanced converter keeps from a turret slot (its death kills one within 173)
            float LayoutFusionNanoGap = 0.0f;        // ... a fusion (379); density and shared build power were chosen over firebreaks
            int LayoutFallbackShakeCells = 8;        // no box: economy within this of the factory nanos (the only spiral left)

            /******************** ECO PLANNER (D-058) ********************/
            // EcoPlanner (manager/eco_planner.as): a deterministic function of
            // wind range, tidal, incomes, banks and what stands that names the
            // next economy structure; re-evaluated every time a constructor asks.
            // It replaces the solar / advanced solar / converter / fusion rungs
            // of this role's ladders; mexes stay native's. doc/eco-planner.md.
            bool EcoPlannerEnabled = true;
            float EcoEnergyRatioLow = 8.0f;          // E per M wanted at EcoEnergyRampStart metal
            float EcoEnergyRatioHigh = 20.0f;        // ... and from EcoEnergyRampEnd up (T2 economies)
            float EcoEnergyRampStart = 5.0f;
            float EcoEnergyRampEnd = 40.0f;
            float EcoEnergyReserve = 60.0f;          // E/s wanted on top (the commander's 30 and build draw)
            float EcoEnergyLowPercent = 0.25f;       // bank below this and pull over income = draining
            float EcoConvertEnergyPercent = 0.90f;   // bank at this = floating: convert the surplus
            float EcoFloatMetalPercent = 0.80f;      // metal bank at this = invest in energy anyway
            float EcoAffordSeconds = 90.0f;          // a lump is affordable within this many seconds of income
            float EcoWindMinimum = 7.0f;             // effective wind E/s under this and turbines are not an option
            float EcoWindLullFloor = 4.0f;           // min wind under this discounts the average ...
            float EcoWindLullFactor = 0.7f;          // ... by this
            float EcoAdvSolarMinMetalIncome = 6.0f;  // an advanced solar's 350 lump waits for this income (or the bank)
            int EcoStorageWinds = 4;                 // this many winds and no energy storage: build one
            float EcoStorageSeconds = 20.0f;         // energy storage under this many seconds of income: another
            int EcoMaxEnergyStorages = 1;
            float EcoStorageMinMetalBank = 150.0f;   // no storage order on an empty bank (played: the rule looped at 0 metal)
            float EcoConverterUse = 70.0f;           // a T1 converter's draw; a surplus of twice this converts even while energy is going up
            float EcoAssistRadius = 1200.0f;         // a builder assists the energy structure going up only within this of itself (bots are slow)
            float EcoFusionEnergyIncome = 300.0f;    // from this energy income, a T2 builder answers "energy" with a fusion (advanced when its metal gate passes); T1 builders leave energy alone
            int EcoMaxMetalStorages = 2;
            int EcoMetalMapSpots = 150;              // this many metal spots or more counts as a metal map
            bool EcoOneEnergyAtATime = true;         // no new energy structure while one is under construction (unless the bank drains)
            // Build power (D-063): a turret goes up when the assist power around
            // the base is under this much per metal income - about what T2 work
            // spends - or more when metal floats; the layout picks the slot,
            // nearest the factories first.
            float EcoBuildPowerPerMetal = 8.0f;
            float EcoBuildPowerFloatFactor = 1.5f;
            float EcoBuildPowerRadius = 700.0f;
            float EcoTurretMinMetalIncome = 8.0f;
            float EcoTurretBankFraction = 0.5f;      // this share of a turret's metal banked before one starts
            float EcoTurretAssistRadius = 1200.0f;   // a constructor assists a turret going up within this of the base centre

            /******************** ECONOMY SWITCH (D-054) ********************/
            // TECH starts on the shared economy.json defaults (native reclaim
            // efficiency 20, json energy limits, native assist nanos on) and
            // switches to its own settings below - ReclaimEnergyEff,
            // EnergyLimit*, AssistNano* - once both incomes reach these floors.
            // false: the settings apply at init, as before.
            bool EconomySwitchEnabled = true;
            float EconomySwitchMetalIncome = 20.0f;
            float EconomySwitchEnergyIncome = 1000.0f;

            /******************** ENERGY (per-role, D-047) ********************/
            // economy.json is shared by every role; these go through
            // aiEconomyMgr and change only this instance.
            // Old energy is reclaimed when a finished energy def scores more
            // than reclEnergyEff x the old def's score (native default 20 -
            // never for a solar against an advanced solar). 2 reclaims solars
            // once advanced solars stand and advanced solars once a fusion does.
            float ReclaimEnergyEff = 2.0f;
            bool ReclaimOldConvertersAlways = true;
            // Caps on the energy table for this role; -1 keeps economy.json's.
            int EnergyLimitSolar = -1;
            int EnergyLimitAdvSolar = -1;

            /******************** TECH BASE SETTINGS ********************/
            // All settings applied to tech role at game start, logic can change throughout game
            float AllyRange = 1000.0f;

            // Legacy knob used across TECH logic for rush count; keep for compatibility.
            // Consider reconciling with strategies in future refactors.
            int NukeRush = 1;

            /******************** TECH MILITARY QUOTAS ********************/
            // Scout unit cap for TECH role
            int MilitaryScoutCap = 0;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 1.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 30.0f;
            float MilitaryRaidAvgPower = 30.0f;
            // Defence helper gate: below this metal income, use default defence logic
            float MilitaryDefenceMetalIncomeThreshold = 300.0f;

            /******************** TECH ECONOMY SETTINGS ********************/
            //Minimum incomes levels before T2 bot lab will be built
            float MinimumMetalIncomeForT2Lab = 18.0f; 
            float MinimumEnergyIncomeForT2Lab = 250.0f;
            // Additional gating: require at least this much stored metal and cap total T2 bot labs
            int MaxT2BotLabs = 3;

            //Minimum incomes levels before normal Fusion will be built
            float MinimumMetalIncomeForFUS = 20.0f; 
            float MinimumEnergyIncomeForFUS = 700.0f;
            float MaxEnergyIncomeForFUS = 2000.0f;

            //Minimum incomes levels before Advanced Fusion will be built
            float MinimumMetalIncomeForAFUS = 70.0f; 
            float MinimumEnergyIncomeForAFUS = 2000.0f;

            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f; 

            //Stop building advanced solar if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1000.0f; 
            //Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 600.0f; 
            // Max number of advanced solars allowed for TECH role
            int MaxAdvancedSolars = 8;
            
            // Consider energy storage "low" when current < storage * percent
            float EnergyStorageLowPercent = 0.90f;

            // Radius used to consider mex-upgrade tasks "near base"

            // Minimum energy income to allow assisting freelance T2 near mex upgrades

            // Minimum incomes for building advanced energy converter (moho maker)
            float MinimumMetalIncomeForAdvConverter = 18.0f;
            float MinimumEnergyIncomeForAdvConverter = 1200.0f;

            /******************** GANTRY THRESHOLDS ********************/
            // D-288: MetalIncomePerGantry (250) and EnergyIncomePerGantry (6000) are
            // retired; TechGantryScale owns the gantry count (GantryScale* above).

            /******************** T2 BOT LAB THRESHOLDS (income-scaled) ********************/
            // Income required per allowed T2 Bot Lab (mirrors gantry logic). Allowed labs =
            // min(floor(mi / MetalIncomePerT2Lab), floor(ei / EnergyIncomePerT2Lab)), with a minimum of 1.
            // Defaults mirror legacy single-lab thresholds.
            float MetalIncomePerT2Lab = 100.0f;
            float EnergyIncomePerT2Lab = 1000.0f;

            /******************** TECH ECO PHASE THRESHOLDS ********************/
            // Metal income thresholds for bot-lab expansion behavior.
            // Default gate (affects both T1 and T2 expansion behaviors)
            float MetalIncomeThresholdForBotLabExpansion = 200.0f;
            // Early gate: used when the early-expansion strategy is enabled (formerly "rush")
            float MetalIncomeThresholdForEarlyBotLabExpansion = 100.0f; // TODO: tune per profile

            // Metal income thresholds for vehicle-plant expansion behavior.
            // Default gate (affects both T1 and T2 expansion behaviors)
            float MetalIncomeThresholdForVehiclePlantExpansion = 500.0f;
            // Early gate: used when the early-expansion strategy is enabled (formerly "rush")
            float MetalIncomeThresholdForEarlyVehiclePlantExpansion = 400.0f;

            // T1 Energy converter policy (configurable thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 18.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 200.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;

            // If metal income is below this, secondary T2 will assist primary T2

            /******************** AIRCRAFT PLANT THRESHOLDS ********************/
            // Economy thresholds for building aircraft plants (used by generic rules)
            float RequiredMetalIncomeForAirPlant = 60.0f;
            float RequiredMetalCurrentForAirPlant = 1000.0f;
            float RequiredEnergyIncomeForAirPlant = 2000.0f;

            // T2 Aircraft Plant thresholds (TECH role)
            // Mirrors AIR role defaults; scoped to TECH so roles don't cross-reference
            float RequiredMetalIncomeForT2AircraftPlant = 200.0f;
            float RequiredEnergyIncomeForT2AircraftPlant = 2000.0f;

            /******************** LANDLOCKED WATER EXPANSION ********************/
            // Only on a start spot the map script flags landLocked (Global::Map::LandLocked).
            // Shipyards and hover plants stay capped at 0 until metal income reaches the
            // gate; then the caps below apply and Tech_TryEnqueueLandLockedWaterFactory
            // places them from the T2 constructor ladder. See tech.as, LANDLOCKED WATER EXPANSION.
            float MetalIncomeThresholdForLandLockedWaterExpansion = 200.0f;
            int LandLockedMaxT1Shipyards = 1;
            int LandLockedMaxT2Shipyards = 1;
            int LandLockedMaxHoverPlants = 1;   // land and floating variants combined
            // Energy income required on top of the metal gate before the T2 shipyard
            float LandLockedMinEnergyIncomeForT2Shipyard = 2000.0f;
            // How far (elmos) around the T2 bot lab the site search may look for water
            // when placing the T1 shipyard from a land base (120 map squares)
            float LandLockedShipyardSearchRadius = 960.0f;

            /******************** WORKFORCE MINIMUMS ********************/
            // Minimum desired numbers of constructor bots by tech tier
            int MinimumT1ConstructorBots = 2;
            int MinimumT2ConstructorBots = 1;
            int T2BotConstructorCap = 10;                   // D-119 (owner): T2 construction bots at most this many for TECH (the T2 air constructors keep T2ConstructorCap)
            int FastAssistBotCap = 10;                      // D-119 (owner): fast assist bots (Fark, Freaker, legaceb) at most this many
            float FastAssistMetalReserve = 2000.0f;
            // D-308: compact banks need mobile support sooner; retain the hard
            // cap and rush budget, with no extra polling or recruit batches.
            float CompactFastAssistIncomeScale = 2.0f;
            float CompactFastAssistMetalReserve = 1000.0f;
            int T2ConstructorCap = 60;                      // D-103: T2 constructors (bot and air) produced up to this while the metal bank is over T2ConstructorBankShare
            float T2ConstructorBankShare = 0.5f;            // D-103: the metal bank share of storage above which the advanced lab makes T2 constructors
            // T2 constructors TECH keeps before it builds any for an ally's
            // request (played: every one it made was ferried away, and the
            // advanced lab built nothing else).
            int DonationKeepT2Constructors = 2;

            /******************** BUILDER CAP LIMITS ********************/
            // Hard caps for T1/T2 land builders used when computing income-based limits
            int MaxT1Builders = 5;
            int MaxT2Builders = 3;

            /******************** TECH START LIMIT CAPS ********************/
            // Initial caps applied at game start for the TECH role
            int StartCapRezBots = 0;
            int StartCapFastAssistBots = 10;                // D-119 (owner): was 50

            int StartCapT1BotLabs = 1;
            int StartCapT2BotLabs = 1;
            int StartCapT1VehiclePlants = 0;

            // Aircraft plants (separate in case behavior diverges later)
            int StartCapT1AircraftPlants = 0;
            int StartCapT2AircraftPlants = 0;

            // Max allowed aircraft plants for TECH policy
            int MaxT1AircraftPlants = 1;

            // Air combat units (non-construction aircraft)
            int StartCapT1AirCombatUnits = 0;
            int StartCapT2AirCombatUnits = 0;

            // Shipyards (water)
            int StartCapT1Shipyards = 0;
            int StartCapT2Shipyards = 0;

            // Energy structures
            int StartCapT1Solar = 4;
            int StartCapFusionReactors = 0;
            int StartCapAdvancedFusionReactors = 0;

            // Combat unit caps at start (TECH role disables T1/T2 combat by default)
            int StartCapT1CombatUnits = 0;
            int StartCapT2CombatUnits = 0;

            /******************** NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap.
            // 15 metal per nano (was 10): at +30 that is two turrets, not
            // three, while the T2 lab is still paying for its first
            // constructor (D-051).
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 15.0f;   // metal per nano
            int NanoMaxCount = 200;
            // No new nano while the first T2 constructors are being paid for
            // (a T2 bot lab stands and fewer than MinimumT2ConstructorBots
            // exist), nor while the bank is below NanoMinMetalCurrent: a
            // turret then only deepens the stall on the constructor.
            bool NanoHoldForFirstT2Constructors = true;
            float NanoMinMetalCurrent = 150.0f;
            // Native assist nanos (CEconomyManager::CheckAssistRequired) are a
            // second, script-blind source of HIGH-priority turrets; TECH turns
            // them off and owns the count above. Set true to restore them,
            // AssistNanoIncomeMod then scales the income they must be covered by.
            bool AssistNanoEnabled = false;
            float AssistNanoIncomeMod = 1.0f;
            // Reserves-based nano condition: build when metalCurrent >= threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            /******************** T2 BOT DONATION ********************/
            // Team::Donation (manager/donation.as): give N of the T2 combat bots
            // the advanced lab batches to the closest allies, N drawn once from
            // weight(k) = Decay^(k-Min) over Min..Max. Constructors are never part
            // of this; a teammate that wants one asks (Global::ConstructorRequest).
            int T2BotDonationMin = 2;
            int T2BotDonationMax = 7;
            float T2BotDonationDecay = 0.6f;

            /******************** NUCLEAR SILO THRESHOLDS ********************/
            // First strike: how long the first silo keeps the farthest Tech start as its
            // forced target (CSuperTask::SetTargetPos) before native targeting resumes
            int NukeFirstStrikeOverrideSeconds = 30;
            // Separate economy thresholds for rush vs regular nuclear silo builds
            // Rush thresholds: used when rushing up to NukeRush silos
            float MinimumMetalIncomeForNukeRush = 50.0f;
            float MinimumEnergyIncomeForNukeRush = 2000.0f;
            // Regular thresholds: used for non-rush nuking policy
            float MinimumMetalIncomeForNuke = 600.0f;
            float MinimumEnergyIncomeForNuke = 10000.0f;
            
            /******************** ANTI-NUKE THRESHOLDS ********************/
            // Minimum economy thresholds to allow building anti-nuke defenses
            // and the minimum number of anti-nuke structures to maintain
            float MinimumMetalIncomeForAntiNuke = 80.0f;
            float MinimumEnergyIncomeForAntiNuke = 3000.0f;
            int MinimumAntiNukeCount = 1;
            // Income-scaling for anti-nukes: allowed count = floor(metalIncome / MetalIncomePerAntiNuke)
            float MetalIncomePerAntiNuke = 80.0f;
            
        }
}
}
