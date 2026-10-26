// FRONT defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/front/front.as
namespace Global {
namespace RoleSettings {
namespace Front {
            bool GeothermalEnabled = true;
            uint GeothermalBuilders = 2;
            float GeothermalRadius = 3200.0f;
            // FRONT funds a T1 vent over three minutes while reserving half
            // its conservative income for units and ordinary energy growth.
            float GeothermalBudgetSeconds = 180.0f;
            float GeothermalIncomeFraction = 0.5f;
            float GeothermalBootstrapEnergy = 120.0f;

            // First factory at the spawn (owner, 2026-10-19; systems/construction/front_spawn_factory.as).
            // Off here; experimental_balanced turns it on. Until a factory is framed: commander jobs further
            // than the leash radius from the spawn become a solar at the spawn; from SpawnFactorySeconds,
            // while energy income is short of native's start check, every non-energy job does too.
            bool SpawnFactoryEnabled = false;
            int SpawnFactorySeconds = 45;
            float SpawnFactoryLeashRadius = 700.0f;   // 0 = no leash
            int SpawnFactoryLeashMaxSeconds = 180;    // after this, native as before

            // Role switch cadence (seconds)
            int MinAiSwitchTime = 20;
            int MaxAiSwitchTime = 60;

            // NukeLimit: maximum number of nukes allowed for FRONT role
            /******************** FRONT BASE SETTINGS ********************/
            // All settings applied to front role at game start, logic can change throughout game
            float AllyRange = 900.0f;

            /******************** FRONT MILITARY QUOTAS ********************/
            // Scout unit cap for FRONT role (defaults)
            // Attack gate (required power to trigger attack waves) (defaults)
            // Raid thresholds (power) (defaults)

            // Split thresholds by opening: bots vs vehicles.
            // These default to the baseline values above; tweak per-profile as needed.
            int MilitaryScoutCapBots = 7;
            int MilitaryScoutCapVehicles = 2;
            float MilitaryAttackThresholdBots = 12.0f;
            float MilitaryAttackThresholdVehicles = 30.0f;
            float MilitaryRaidMinPowerBots = 12.0f;
            float MilitaryRaidMinPowerVehicles = 40.0f;
            float MilitaryRaidAvgPowerBots = 60.0f;
            float MilitaryRaidAvgPowerVehicles = 180.0f;

            // Number of T1 scouts/raiders to rush from the very first T1 land factory
            // Only applies to the first T1 Bot Lab or Vehicle Plant built; subsequent factories use normal logic
            int ScoutRushCount = 1;

             /******************** FRONT NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            float NanoEnergyPerUnit = 150.0f; // energy per nano
            int NanoMaxCount = 200; 
            int NanoMinCount = 1;
            float NanoEnergyIncomeThresholdForMax = 2000.0f;
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            // Minimum constructor maintenance targets for factory recruitment
            int MinT1BotConstructorCount = 1;
            int MinT1VehicleConstructorCount = 1;

            // Minimum T2 constructor targets for FRONT role.
            // These mirror TECH's MinimumT2ConstructorBots but are scoped to FRONT so
            // front.as can enforce its own T2 constructor policy without cross-referencing.
            int MinT2BotConstructorCount = 1;
            int MinT2VehicleConstructorCount = 1;

            // Time triggers for T2 lab construction
            int TimeTriggerForFirstT2LabSeconds = 22 * 60; // 22 minutes
            // The time trigger above fires only while metal income is at least this (0 = no floor, as before).
            // Stops a FRONT that lost its base from ordering a T2 lab/plant at +3 metal right after rebuilding a T1 factory.
            float TimeTriggerForFirstT2LabMinMetalIncome = 0.0f;
            int TimeTriggerForT2EcoGatingSeconds = 20 * 60; // 20 minutes

            // Combat settings
            int DefaultT1CombatFireState = 3;

            // Start Caps
            int StartCapRezBots = 10;
            int StartCapT1AircraftPlants = 0;
            int StartCapNukeSilos = 0;

            // Dynamic Quota Settings
            float DynamicQuotaEnemyCostAttackThresholdMultiplier = 1.0f;
            float DynamicQuotaEnemyCostWithdrawThresholdMultiplier = 0.8f;
            float UnderpoweredAttackQuota = 100.0f;
            float UnderpoweredRaidMinQuota = 100.0f;
            float UnderpoweredRaidAvgQuota = 200.0f;
            int DynamicQuotaDelaySeconds = 2 * 60;

            // Economy Scaling Limits
            float MetalIncomePerLab = 35.0f;
            float MetalIncomeForGantry = 225.0f;   // owner, 2026-10-25 (175 before)
            // Owner (2026-10-25): without the eco ladder, the T2 constructors order the gantry themselves at
            // MetalIncomeForGantry (roles/front/front.as Front_TryLadderGantry), not the native factory switch
            bool DirectGantry = true;
            // Owner (2026-10-16): once a fusion stands FRONT reclaims its winds and solars, those within
            // ReclaimNearFactoryRadius of a factory first (played: Fatboys boxed in by advanced solars and
            // winds round the labs), advanced solars too at ReclaimAdvSolarMargin or with an advanced fusion.
            // Off here, on in experimental_balanced (systems/construction/front_reclaim.as).
            bool ReclaimT1EnergyAfterFusion = false;
            float ReclaimT1EnergyMargin = 1.25f;    // energy income without winds/solars covers the pull by this
            float ReclaimAdvSolarMargin = 1.5f;     // ... without advanced solars as well
            float ReclaimNearFactoryRadius = 900.0f;
            float ReclaimEnergyRadius = 3000.0f;   // from the worker
            int ReclaimEnergyConcurrent = 3;
            // Owner (2026-10-16, 2026-10-17): FRONT's eco climbs to a gantry. Three fusions (winds, solars,
            // advanced solars and T1 converters reclaimed once the first stands), one advanced fusion, a
            // second (the fusions reclaimed as it builds), then the gantry, its EcoLadderGantryNanos turrets
            // ordered from the moment it is framed. T2 converters from the first fusion while energy would
            // be wasted (EcoLadderT2ConverterEnergy, EcoLadderT2ConverterReserve); past two advanced fusions,
            // one more at a time until metal income reaches EcoLadderGantryMetalIncome, which the gantry
            // waits for; once it stands with its turrets, advanced fusions resume. Converters only with the
            // energy bank at EcoLadderConvertBankPercent. The stage caps the native eco too (fusions 3,
            // advanced fusions 2, then EcoLadderMaxAdvFusions). Off here, on in experimental_balanced
            // (systems/construction/front_eco_ladder.as). Log [FRONT][Eco].
            bool EcoLadder = false;
            float EcoLadderFusionMetalIncome = 20.0f;     // first, second and third fusion
            float EcoLadderAdvFusionMetalIncome = 30.0f;  // first and second advanced fusion
            float EcoLadderStoredFraction = 0.3f;         // or a bank of this share of its metal cost
            int EcoLadderT1Converters = 5;                // unused since 2026-10-17 (no T1 converters once a fusion stands)
            int EcoLadderT2ConvertersTwoFusions = 2;      // unused since 2026-10-17 (surplus-based)
            int EcoLadderT2ConvertersPerAdvFusion = 3;    // unused since 2026-10-17 (surplus-based)
            int EcoLadderMaxT2Converters = 30;
            // T2 converters from the first fusion: one more while energy income beats the pull by a
            // converter's draw plus this reserve and the bank is at EcoLadderConvertBankPercent (owner, 2026-10-17)
            float EcoLadderT2ConverterEnergy = 600.0f;
            float EcoLadderT2ConverterReserve = 200.0f;
            float EcoLadderConvertFullPercent = 0.9f;     // or one more whenever the energy bank is this full
            int EcoLadderMaxAdvFusions = 8;               // past two, one after another while metal income is under the gantry's, and after it
            int EcoLadderGantryNanos = 6;                 // caretaker turrets on the gantry before advanced fusions resume
            int EcoLadderFrameHelpers = 4;                // the ladder's constructors on a reactor frame at a time
            float EcoLadderFrameHelpRadius = 3000.0f;     // a frame this near the constructor
            float EcoLadderConvertBankPercent = 0.6f;
            int EcoLadderGantryAfterAdvFusions = 2;       // the gantry step once this many advanced fusions stand (1 in experimental_balanced)
            // FRONT recovery after losing the base (systems/construction/front_recovery.as); off here, on in experimental_balanced
            bool Recovery = false;
            float RecoveryEnterMetalIncome = 15.0f;      // recovery starts below this metal income...
            float RecoveryMinPeakMetalIncome = 40.0f;    // ...once income had reached this
            float RecoveryExitMetalIncome = 30.0f;       // and ends after RecoveryExitSeconds at or above this
            int RecoveryExitSeconds = 30;
            float RecoveryMexRadius = 2500.0f;           // mex spots retaken within this of the start (then of the worker)
            int RecoveryMinT1Constructors = 3;           // the T1 factory makes this many constructors first
            bool EcoLadderLaterAdvFusionAtStart = false;  // second and later advanced fusions tried at the start before the eco anchor
            float EcoLadderGantryMetalIncome = 225.0f;    // the gantry waits for this metal income (owner, 2026-10-16; 225 since 2026-10-25)
            float EcoLadderFusionReclaimMargin = 1.0f;    // income without the fusion covers the pull (always once the second advanced fusion stands)
            float EcoLadderAnchorBack = 400.0f;           // eco this far behind the start, away from the map centre
            int EcoLadderMetalStorages = 2;               // from the first advanced fusion, while storage is under a fusion's cost plus the spare
            float EcoLadderStorageSpare = 1000.0f;
            int EcoLadderLogSeconds = 60;
            float MetalIncomePerT1Builder = 20.0f;
            int MinBuilderCap = 5;
            float MetalIncomePerT2Builder = 40.0f;

            // Misc Logic Settings
            int RaiderOpenerCount = 10;
            // Opt-in profile policy: retain the first scout, then choose tanks.
            float VehicleTankOpenerChance = 0.0f;
            int VehicleTankGatherSeconds = 300; // release a disrupted/incomplete batch
            // Owner (2026-10-19): after the opener and until a T2 factory stands, a T1 vehicle plant rolls
            // every VehicleTankMassIntervalSeconds; on VehicleTankMassChance it builds VehicleTankMassMin..Max
            // (random) medium tanks (Stout/Brute/Decurion) in succession, held at the plant until the last is
            // out, then on normal orders. Off here, on in experimental_balanced (systems/production/front_tank_mass.as).
            float VehicleTankMassChance = 0.0f;
            int VehicleTankMassIntervalSeconds = 180;
            int VehicleTankMassMin = 5;
            int VehicleTankMassMax = 8;
            int VehicleTankMassGatherSeconds = 480; // release a disrupted/incomplete mass
            // Owner (2026-10-19): the same for a finished T2 vehicle plant, all game: Bull/Tiger/Prometheus,
            // held until the last is out, then sent at the enemy as one attack squad. Off here, on in experimental_balanced.
            float VehicleT2TankMassChance = 0.0f;
            int VehicleT2TankMassIntervalSeconds = 180;
            int VehicleT2TankMassMin = 5;
            int VehicleT2TankMassMax = 8;
            int VehicleT2TankMassGatherSeconds = 600;
            // Owner (2026-10-19): each T2 wave also gets a radar jammer, radar and flak vehicle from the same plant,
            // moved every WaveEscortUpdateSeconds to the wave's safe centre (its tanks' centroid, WaveEscortBehind
            // back toward our start) once that moves WaveEscortRepath. Off here (systems/production/front_wave_escort.as).
            bool VehicleT2WaveEscorts = false;
            float WaveEscortBehind = 150.0f;   // owner (2026-10-20): close behind, moving with the group
            int WaveEscortUpdateSeconds = 2;
            float WaveEscortRepath = 120.0f;
            // Owner (2026-10-20): on the same T2 roll, VehicleT2ArtySquadChance for a faction artillery squad held until
            // complete, then led by its Starlight/Quaker/Cleaver, which stops at ArtySquadRangeFraction of its range from
            // the nearest known enemy; the rest follow ArtySquadFollowBehind behind, all on hold position and fire at will.
            // Off here (systems/production/front_arty_squad.as).
            float VehicleT2ArtySquadChance = 0.0f;
            int ArtySquadUpdateSeconds = 2;
            float ArtySquadRangeFraction = 0.95f;
            float ArtySquadCohesion = 450.0f;
            float ArtySquadFollowBehind = 120.0f;
            float ArtySquadRepath = 96.0f;
            int ArtySquadStragglerSeconds = 60;   // longest the lead waits for stragglers before advancing anyway
            // Owner (2026-10-19): bot lab FRONTs, from the opener wave until a T2 factory stands: every
            // BotWaveIntervalSeconds, BotWaveChance for BotWaveMin..Max Pawns/Grunts (Goblins: BotWaveGoblinMin..Max),
            // held at the lab until the last is out, then one attack wave. Off here, on in experimental_balanced.
            float BotWaveChance = 0.0f;
            int BotWaveIntervalSeconds = 180;
            int BotWaveMin = 10;
            int BotWaveMax = 15;
            int BotWaveGoblinMin = 15;
            int BotWaveGoblinMax = 20;
            int BotWaveGatherSeconds = 360;
            float SwitchFactoryCostMultiplier = 1.2f;
            int ScoutAssignmentLimit = 5;
            float BuilderCostThresholdForBase = 200.0f;

            // Nano Policy Extras
            float NanoMinIncomeForFirst = 10.0f;
            float T2LabStoredMetalThresholdRatio = 0.9f;

            // Transition thresholds for switching between T1 factory types (Bot <-> Vehicle)
            float MinimumMetalIncomeForT1FactoryTransition = 200.0f;

            /******************** FRONT T2 LAB THRESHOLDS ********************/
            // Economy thresholds and caps for building a T2 Bot Lab when in FRONT role
            // Mirrors FrontTech defaults but scoped to Front so front.as does not reference FrontTech settings.
            // Special-case: first T2 lab/plant fast-track threshold (bot or vehicle) when none exist yet
            // If total T2 labs (bot + vehicle) < 1 and metal income >= this, FRONT will attempt to build one.
            float MinimumMetalIncomeForFirstT2Lab = 50.0f;
            float MinimumMetalIncomeForT2Lab = 40.0f;
            float MinimumEnergyIncomeForT2Lab = 2000.0f;
            float RequiredMetalCurrentForT2Lab = 200.0f;

            // Vehicle-specific T2 thresholds
            float MinimumMetalIncomeForFirstT2VehiclePlant = 50.0f;

            int MaxT2BotLabs = 1;
            int MaxT2VehicleLabs = 1;

            /******************** FRONT ECONOMY SETTINGS ********************/
            // Consider energy storage "low" when current < storage * percent
            float EnergyStorageLowPercent = 0.90f;

            // Minimum incomes levels before normal Fusion will be built
            float MinimumMetalIncomeForFUS = 40.0f; 
            float MinimumEnergyIncomeForFUS = 1200.0f;
            float MaxEnergyIncomeForFUS = 4000.0f;

            // T2 mex upgrades first (owner, 2026-10-22; systems/construction/front_mex_upgrade.as):
            // a FRONT T2 constructor upgrades our T1 mexes before assisting factories or other
            // constructors' non-mex work, after the eco ladder's own reactor orders. Helpers already on
            // a shared assist/build are pulled to an open upgrade (never a task's last builder).
            bool MexUpgradeFirst = true;
            float MexUpgradeRadius = 100000.0f;   // from the start position; every mex we hold
            int MexUpgradeMaxConcurrent = 3;      // MEXUP tasks of ours at once
            int MexUpgradeScanSeconds = 3;        // how often busy helpers are reconsidered

            // T2 lab turrets (owner, 2026-10-25; systems/construction/front_factory_nanos.as): from the moment
            // a T2 bot lab or vehicle plant of ours is framed, FRONT T1 constructors asking for work within
            // T2FactoryNanoReach build its turrets until T2FactoryNanos stand, are framed or are ordered there,
            // at most T2FactoryNanoParallel orders at once (past that they help a turret frame). The turret
            // cap is raised by the turrets still missing. 0: off here; experimental_balanced sets 6 (the
            // Armada and Legion T2 labs' caretaker in factory.json). Log [FRONT][LabNano].
            int T2FactoryNanos = 0;
            int T2FactoryNanosMax = 0;                 // rising to this as the metal bank nears overflow (experimental_balanced 14)
            float T2FactoryNanoBankLow = 0.5f;         // ... from this share of metal storage (none extra)
            float T2FactoryNanoBankHigh = 0.9f;        // ... to this one (all of them)
            int T2FactoryNanoParallel = 3;
            float T2FactoryNanoStartProgress = 0.0f;   // the lab frame's build progress before the first turret
            float T2FactoryNanoRadius = 400.0f;        // a turret this near (and nearer than any other factory) is the lab's
            float T2FactoryNanoReach = 2500.0f;        // idle, guarding or assisting constructors this near the lab are asked
            float T2FactoryNanoTakeRadius = 1200.0f;   // ... and ones walking to an unframed build this near
            int T2FactoryNanoScanSeconds = 2;          // turret count refresh while a lab is short
        }
}
}
