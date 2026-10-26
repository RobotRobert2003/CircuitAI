// TACTICAL defaults. Namespaces and mutable values are API-compatible.
// Profile hooks/JSON loaders may override these; do not reapply defaults at runtime.
// Role entry: ../../roles/tactical/tactical.as
namespace Global {
namespace RoleSettings {
namespace Tactical {
            // Local recovery is used only when native opening selection waits
            // without a factory task. Keep normal productive openings intact.
            float OpeningRecoveryRadius = 1024.0f;
            int OpeningRecoveryTimeoutSeconds = 60;
            // D-352: a race-won spot the team owns beyond the home area (a summit, an
            // island only hovers and aircraft reach) is ordered by an idle hover
            // constructor once income allows, one remote job at a time.
            float TheatreMexMetal = 8.0f;      // metal income before a hover constructor leaves the home area for one
            float TheatreMexRadius = 6000.0f;  // from the start (Supreme's west summits are 5,600 elmos from the TACTICAL start)
            float TheatreMexThreat = 0.5f;     // skip a spot whose enemy clock has passed while surface threat there exceeds this
            /******************** SEA BASE SETTINGS ********************/
            // All settings applied to sea role at game start, logic can change throughout game
            float AllyRange = 3000.0f;

            /******************** SEA MILITARY QUOTAS ********************/
            // Scout unit cap for SEA role
            int MilitaryScoutCap = 4;
            // Attack gate (required power to trigger attack waves)
            float MilitaryAttackThreshold = 20.0f;
            // Raid thresholds (power)
            float MilitaryRaidMinPower = 30.0f;
            float MilitaryRaidAvgPower = 60.0f;

            /******************** HOVER SEA NANO POLICY ********************/
            // How much income per additional T1 nano caretaker; and cap
            // Reserves-based nano condition threshold

            /******************** TACTICAL ECONOMY SETTINGS (formerly HOVER_SEA) ********************/
            
            //Continue building normal solars if ever below this energy income level
            float SolarEnergyIncomeMinimum = 160.0f; 
            // Continue building advanced solars if ever below this energy income level
            float AdvancedSolarEnergyIncomeMinimum = 1200.0f;
            // Stop building advanced solars if above this energy income level
            float AdvancedSolarEnergyIncomeMaximum = 3000.0f;

            // Minimum metal income to trigger building an Advanced Vehicle Plant (T2 Vehicle Lab)
            float RequiredMetalIncomeForT2VehiclePlant = 25.0f;

            // Minimum number of T1 hover constructors to maintain via Hover plant production
            int MinHoverConstructorCount = 10;

            // Income-scaled Hover Plant policy
            // Build allowance: 1 base plant + floor(metalIncome / MetalIncomePerExtraHoverPlant),
            // clamped to MaxHoverPlants. Defaults: +1 per 50 metal income, max 3 plants total.
            float MetalIncomePerExtraHoverPlant = 50.0f;
            int MaxHoverPlants = 3;
            // A construction ship TACTICAL owns runs SEA's naval ladder with
            // SEA's numbers (helpers/sea_constructor_helpers.as, D-042).
            bool SeaConstructorMimicsSea = true;

            /******************** TACTICAL START LIMIT CAPS ********************/
            // Initial caps applied at game start for the TACTICAL role (formerly HOVER_SEA)
            int StartCapT1BotLabs = 0;
            int StartCapT2BotLabs = 0;
            int StartCapT1VehiclePlants = 0;

            // Aircraft plants
            int StartCapT1AircraftPlants = 0;
            int StartCapT2AircraftPlants = 0;

            // Shipyards (water)
            int StartCapT1Shipyards = 0;
            int StartCapT2Shipyards = 0;
        }
}
}
