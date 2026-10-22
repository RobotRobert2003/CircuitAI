// Centralize unit lists in UnitHelpers
#include "../units/unit_helpers.as"
#include "../../types/ai_role.as"
#include "../../define.as"

// Helpers for quickly disabling tiers of combat units by side.
// NOTE: Unit names are placeholders where uncertain; verify against resources/data/units.json.
// Policy: Only combat units are targeted (not constructors or factories).
namespace RoleLimitHelpers {
    void _setAll(dictionary@ d, array<string>@ names, int cap) {
        for (uint i = 0; i < names.length(); ++i) { d.set(names[i], cap); }
    }

    // Disable Tier 1 combat units
    void DisableT1Combat(dictionary@ d, const string &in side) {
        if (side == "armada") { array<string> arm = UnitHelpers::GetArmadaT1CombatUnits(); _setAll(d, arm, 0); }
        else if (side == "cortex") { array<string> cor = UnitHelpers::GetCortexT1CombatUnits(); _setAll(d, cor, 0); }
        else if (side == "legion") { array<string> leg = UnitHelpers::GetLegionT1CombatUnits(); _setAll(d, leg, 0); }
        else { array<string> all = UnitHelpers::GetAllT1CombatUnits(); _setAll(d, all, 0); }
    }

}
