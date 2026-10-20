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
            float MetalIncomeForGantry = 250.0f;
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
            // complete, then led by its Starlight/Quaker/Thanatos, which stops at ArtySquadRangeFraction of its range from
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

            /******************** DYNAMIC FACTORY PRODUCTION ********************/
            // Toggle for role-based dynamic factory production system (replaces factory.json logic)
            // When enabled, FRONT factories (labs, air plants, gantries, etc.) delegate unit
            // selection to FactoryProduction::MakeTask using threat-aware scoring.
            bool UseDynamicFactoryProduction = false;

            /******************** FRONT ECONOMY SETTINGS ********************/
            // Consider energy storage "low" when current < storage * percent
            float EnergyStorageLowPercent = 0.90f;

            // Minimum incomes levels before normal Fusion will be built
            float MinimumMetalIncomeForFUS = 40.0f; 
            float MinimumEnergyIncomeForFUS = 1200.0f;
            float MaxEnergyIncomeForFUS = 4000.0f;
        }
}
}
