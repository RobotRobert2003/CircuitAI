// Role-related small helpers shared across roles
#include "../../define.as"           // for AiRandom
#include "../units/unit_helpers.as"        // for UnitHelpers lab lists
#include "../../types/ai_role.as"  // for AiRole enum

namespace RoleHelpers {

	// Determine a default role based on the terrain type of the default factory.
	// For land factories, return a weighted random role:
	//   10% SUPPORT, 10% AIR, 15% TECH, 65% FRONT
	// For water factories -> SEA. Unknown factories default to FRONT.
	AiRole DefaultRoleForFactory(const string &in defaultStartFactory)
	{
		if (UnitHelpers::FactoryIsLand(defaultStartFactory)) {
			// Gate TECH / SUPPORT roles by approximate enemy team size. Use the same
			// enemy player count that Military uses for its cost-per-player calculations.
			// This is backed by aiEnemyMgr under the hood once wired there.
			int enemyTeamCount = Military::GetEnemyPlayerCount();
			bool allowTech = (enemyTeamCount >= 5);
			bool allowFrontTech = (enemyTeamCount >= 4);

			// Draw from 0..99 inclusive
			const int roll = AiRandom(0, 99);
			// 0-9 : 10% SUPPORT when allowed; otherwise fall through
			if (roll < 10 && allowFrontTech) {
				return AiRole::SUPPORT;
			}
			// 10-19 : 10% AIR (always allowed)
			if (roll < 20) {
				return AiRole::AIR;
			}
			// 20-34 : 15% TECH when allowed; otherwise fall through to FRONT
			if (roll < 35 && allowTech) {
				return AiRole::TECH;
			}
			// Default or gated-out cases -> FRONT
			return AiRole::FRONT;
		}
		if (UnitHelpers::FactoryIsWater(defaultStartFactory)) {
			return AiRole::SEA;
		}
		return AiRole::FRONT; // fallback for unknown factories
	}

}
