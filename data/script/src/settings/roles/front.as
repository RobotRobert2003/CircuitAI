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
            float MetalIncomeForGantry = 175.0f;
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
            float EcoLadderGantryMetalIncome = 150.0f;    // the gantry waits for this metal income (owner, 2026-10-16)
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
