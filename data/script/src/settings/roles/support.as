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
            int OpeningCombatUnits = 3;
            string ArmadaOpeningCombatUnit = "armfast";
            string CortexOpeningCombatUnit = "corpyro";
            string LegionOpeningCombatUnit = "legstr";
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

            // Legacy ladder only (ExperimentalBuild=false). The shared opening
            // uses TECH's map-aware T2 recipe instead of these admission gates.
            float MinimumMetalIncomeForT2Lab = 17.0f;
            float MinimumEnergyIncomeForT2Lab = 550.0f;
            float RequiredMetalCurrentForT2Lab = 800.0f;

            int MaxT2BotLabs = 1;

            /******************** BUILDER CAP LIMITS ********************/
            // Hard caps for T1/T2 land builders used when computing income-based limits
            int MaxT1Builders = 5;
            int MaxT2Builders = 5;

            // Decoys are combat/deception tools, not routine mobile build power.
            int MaxDecoyCommanders = 0;
            int MaxFastAssistBots = 10;
            float FastAssistMinimumMetalIncome = 40.0f;
            float FastAssistMetalIncomePerBot = 20.0f;
            float FastAssistFundingSeconds = 30.0f;
            float FastAssistFundingShare = 0.70f;
            float FastAssistEnergyReserve = 100.0f;
            int CombatBatchesPerFastAssist = 1;

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
