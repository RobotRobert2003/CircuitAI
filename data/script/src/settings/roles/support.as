// SUPPORT defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/support/support.as
namespace Global {
namespace RoleSettings {
namespace Support {
            // Shared TECH T2 opening and reserved economy; SUPPORT owns combat afterwards.
            bool ExperimentalBuild = true;
            int OpeningT1Constructors = 2;
            int MinimumT2Constructors = 1;
            float HomeMexRadius = 1200.0f;
            float HomeDefenceRadius = 900.0f;
            int ConstructorGiftRetrySeconds = 30;
            int ForwardDefenceIntervalSeconds = 30;
            float ForwardDefenceMetalIncome = 40.0f;
            float ForwardDefenceBudgetSeconds = 30.0f;
            float ForwardDefenceSetback = 400.0f;
            int ForwardDefenceCountPerType = 2;
            /******************** SUPPORT BASE SETTINGS ********************/
            // All settings applied to support role at game start, logic can change throughout game
            float AllyRange = 1300.0f;

            /******************** SUPPORT MILITARY QUOTAS ********************/
            // Scout unit cap for SUPPORT role
            int MilitaryScoutCap = 2;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 12.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 12.0f;
            float MilitaryRaidAvgPower = 60.0f;

            /******************** SUPPORT ECONOMY SETTINGS ********************/
            // Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f;
            // T1 Energy converter policy (Support-specific thresholds)
            // Build converters while metal income is below this threshold
            float BuildT1ConvertersUntilMetalIncome = 18.0f;
            // Require at least this much energy income
            float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
            // Require current energy to be at least this fraction of storage (e.g., 0.90 = 90%)
            float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;
            // Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 600.0f;
            // Stop building advanced solars if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 1000.0f;
            // Owner (2026-10-16): FRONT's fusion-era reclaim for SUPPORT. Once a fusion stands SUPPORT's
            // builders reclaim its winds and solars, those within ReclaimNearFactoryRadius of a factory first,
            // advanced solars too at ReclaimAdvSolarMargin or with an advanced fusion, and its planner stops
            // ordering them. Off here, on in experimental_balanced (systems/construction/front_reclaim.as).
            bool ReclaimT1EnergyAfterFusion = false;
            float ReclaimT1EnergyMargin = 1.25f;    // energy income without winds/solars covers the pull by this
            float ReclaimAdvSolarMargin = 1.5f;     // ... without advanced solars as well
            float ReclaimNearFactoryRadius = 900.0f;
            float ReclaimEnergyRadius = 3000.0f;   // from the worker
            int ReclaimEnergyConcurrent = 3;
            // D-359: SUPPORT scales energy with ordinary fusions, one per shortfall, and
            // offers an advanced fusion only once the 10-second minimum energy income
            // reaches this. TECH goes to the advanced fusion on its metal gate instead;
            // SUPPORT keeps that metal on T2 combat units. 0 removes the gate.
            float AdvancedFusionEnergyIncome = 4000.0f;

            // Legacy ladder only (ExperimentalBuild=false). The shared opening
            // uses TECH's map-aware T2 recipe instead of these admission gates.
            float MinimumMetalIncomeForT2Lab = 17.0f;
            float MinimumEnergyIncomeForT2Lab = 550.0f;
            float RequiredMetalCurrentForT2Lab = 800.0f;

            // D-361: SUPPORT adds T2 bot labs as its income grows: the second once the
            // 10-second minimum metal income reaches T2LabSecondMetalIncome, another per
            // T2LabMetalIncomeStep over it, up to MaxT2BotLabs (the legacy ladder reads the
            // cap too). An extra lab is ordered only while the metal bank is ahead
            // (TechBuild::MetalAhead: full for PowerAheadSeconds, or rising), so it spends
            // a surplus and never the budget of a frame going up; an open cluster is
            // finished whatever the bank. Played before the change: one lab and 21
            // builders held a 15,850 metal bank full from minute 14 to 40 at +145..+207.
            // INV-238 watches a bank full for T2LabOverflowSeconds under the wanted count.
            int MaxT2BotLabs = 4;
            float T2LabSecondMetalIncome = 80.0f;
            float T2LabMetalIncomeStep = 60.0f;
            int T2LabOverflowSeconds = 120;

            /******************** BUILDER CAP LIMITS ********************/
            // Hard caps for T1/T2 land builders used when computing income-based limits
            int MaxT1Builders = 5;
            int MaxT2Builders = 5;

            // Decoys are combat/deception tools, not routine mobile build power.
            int MaxDecoyCommanders = 0;
            int MaxFastAssistBots = 10;      // a cap only: factory.json decides whether to build them

            // Owner (2026-10-25): construction turrets on each finished T2 bot / vehicle lab, as AIR
            // gives a T2 plant (Air::T2ExpansionSupport, Factory::MaxNanosPerT2Factory). 0: off.
            int T2FactoryTurrets = 20;
            float T2FactoryTurretMinMetalIncome = 8.0f;  // as Tech::EcoTurretMinMetalIncome
            int T2FactoryTurretSpare = 6;                // team-wide bound: T2FactoryTurrets per lab plus these

            /******************** FRONT TECH NANO POLICY ********************/
            float NanoEnergyPerUnit = 200.0f; // energy per nano
            float NanoMetalPerUnit = 10.0f;   // metal per nano
            int NanoMaxCount = 200;            // cap
            // Reserves-based nano condition threshold
            float NanoBuildWhenOverMetal = 1000.0f;

            /******************** FRONT TECH ASSIST POLICY ********************/
            // If metal income is below this, secondary T1 will assist primary T1
            float SecondaryT1AssistMetalIncomeMax = 80.0f;

            /******************** COMMANDER FACTORY ASSIST (SUPPORT) ********************/
            // Duration (in seconds) from game start during which the SUPPORT commander
            // will prioritize guarding the primary T1 land factory (bot lab or vehicle plant)
            // instead of falling back to default builder behavior.
            int CommanderFactoryAssistDeadlineSeconds = 80; // default: first 2 minutes

            // Duration (in seconds) for each guard assignment when assisting the
            // primary T1 land factory. Tasks may be renewed while within the
            // assist deadline window.
            int CommanderFactoryAssistGuardTimeoutSeconds = 10; // default: 10-second guard tasks
        }
}
}
