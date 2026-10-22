#include "define.as"
// Strategies enum and helpers
#include "types/strategy.as"
#include "types/profile_controller.as"
#include "settings/defaults.as"

// D-077: a role may veto an energy def by name before any act orders it (the
// shared builder helpers and the eco planner ask); TECH sets it to
// TechBuild::EnergyAllowed so no wind or solar is ordered once a fusion
// stands and no advanced solar once an advanced fusion is under way.
funcdef bool EnergyAllowedFn(const string &in defName);

namespace Global {

    EnergyAllowedFn@ energyAllowed = null;

    namespace Map {
        StartSpot@ NearestMapStartPosition;

        // Commander start capture state (populated via Main::AiUnitAdded)
        bool HasStart = false;
        AIFloat3 StartPos(0,0,0);
        AiRole StartRole = AiRole::FRONT;

        bool MapResolved;
        string MapName;
        bool LandLocked;

        MapConfig Config;

        // Merged map + role unit limits for this game
        // Populated during Setup::setupMap via LimitsHelpers
        dictionary MergedUnitLimits;
    }

    namespace Lookups {
        dictionary LabTerrainDict = UnitHelpers::GetLabsTerrainDict();
    }

    namespace AISettings {
        AiRole Role;
        string Side; // faction side (armada/cortex/legion)
        string StartFactory;
        RoleConfig@ RoleCfg;
    }

    // Mod options pulled from engine/lobby; set during Setup::CheckModOptions
    namespace ModOptions {
        // Set in Setup::CheckModOptions. Content options gate whole unit tiers,
        // so policy that picks units - the porcupine chain above all - has to
        // know which are on.
        bool ExperimentalLegionFaction = false;
        bool ExperimentalExtraUnits = false;
        bool ScavUnitsForPlayers = false;
        int MapWaterLevel = 0;
        bool MapWaterIsLava = false;
        int MaxUnits = 0;
    }

	ProfileController profileController;

    // Spam: economy-gated mass production on parallel routes, see manager/spam.as
    // and doc/spam-routes.md. Units need "attribute": ["spam"] in behaviour.json.
    // Air transport ferry (Team::Ferry, manager/ferry.as). AIR builds one
    // transport for the TECH player on its team when TECH starts its first T2
    // lab; TECH uses it to fly donated T2 constructors to their recipients.
    // Defaults: settings/shared/ferry.as

    // SEA hands a TACTICAL ally one construction ship so it can work the
    // coast beside it (Team::SeaAssist, manager/sea_assist.as).
    // Defaults: settings/shared/constructor_assistance.as

    // Defaults: settings/shared/constructor_assistance.as

    // Defaults: settings/shared/constructor_assistance.as

    // Attack-wave policy for every role (a role overrides in its Init).
    // A DEFEND squad promotes to ATTACK when its power reaches a bar that native
    // re-sets every 5 s from the enemy's groups. The legacy bar was the map-wide
    // second-strongest group - a naval squad waited to outweigh a land army it
    // could never reach, and cruisers massed for most of a game; sprinters and
    // blitz did the same in a TECH base. AttackScale > 0 switches the bar to the
    // strongest group the squad can actually REACH, times this; AttackWaitSeconds
    // > 0 sends any squad that has waited that long at or above quota.attack.
    // Either at 0 restores the legacy rule for that half.
    // Defaults: settings/shared/military.as

    // Defaults: settings/shared/spam.as

    // Role-specific overrideable variables in a dedicated namespace
    namespace RoleSettings {
        // Shared defaults: settings/shared/construction.as
        namespace Tech {
            /******************** TECH STRATEGY TOGGLES ********************/
            // Bitmask of enabled high-level strategies for TECH role.
            // Use Strategy enum values as bit indices. Multiple strategies can be enabled simultaneously.
            uint StrategyMask = 0;

            // Enable a strategy flag (wrapper forwards to StrategyUtil)
            void EnableStrategy(const Strategy s) { StrategyMask = StrategyUtil::Enable(StrategyMask, s); }

            // Check if a strategy is enabled (wrapper forwards to StrategyUtil)
            bool HasStrategy(const Strategy s) { return StrategyUtil::Has(StrategyMask, s); }

        }

        // Defaults: settings/roles/air.as

        // Defaults: settings/roles/front.as

        // Defaults: settings/roles/support.as

        // Defaults: settings/roles/sea.as

    // Defaults: settings/roles/tactical.as

        // --- End role-specific settings ---
    }

}
