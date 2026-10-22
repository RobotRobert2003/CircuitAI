/*
 * SpringUnit.cpp
 *
 *  Created on: Jul 20, 2026
 *      Author: rlcevg
 */

#include "spring/SpringUnit.h"
#include "spring/GuardCommand.h"
#include "util/Defines.h"
#include <algorithm>
#include <cmath>
#include <climits>

#include "SSkirmishAICallback.h"	// "direct" C API
#include "Sim/Units/CommandAI/Command.h"

namespace circuit {

int CUnitAPI::GetVisibleWeaponReload(int unitId,int weaponId) const {
    return sAICallback->Unit_Weapon_getReloadFrame(skirmishAIId,unitId,weaponId);
}
bool CUnitAPI::IsActiveSensor(int unitId) const {
    return sAICallback->Unit_isActivated(skirmishAIId,unitId)
        && !sAICallback->Unit_isBeingBuilt(skirmishAIId,unitId)
        && !sAICallback->Unit_isParalyzed(skirmishAIId,unitId);
}

int CUnitAPI::GetFriendlyUnitIds(std::vector<int>& buffer) const
{
	buffer.resize(MAX_UNITS); // allocated/initialized once, not shrunk each frame
	return std::clamp(sAICallback->getFriendlyUnits(skirmishAIId,buffer.data(),MAX_UNITS),0,MAX_UNITS);
}

void CUnitAPI::GetPosition(int unitId,float* position) const
{
	sAICallback->Unit_getPos(skirmishAIId,unitId,position);
}

void CUnitAPI::GetVelocity(int unitId,float* velocity) const
{
	sAICallback->Unit_getVel(skirmishAIId,unitId,velocity);
}

float CUnitAPI::GetCombatHealth(int unitId) const
{
	// Only called for legally observed friends, lazily once per local snapshot.
	// Frames, stunned units and disarmed weapons cannot justify an assault.
	if(sAICallback->Unit_isBeingBuilt(skirmishAIId,unitId)
		|| sAICallback->Unit_isParalyzed(skirmishAIId,unitId)
		|| sAICallback->Unit_getRulesParamFloat(skirmishAIId,unitId,"disarmed",0.f)>0.f) return 0.f;
	return std::max(0.f,sAICallback->Unit_getHealth(skirmishAIId,unitId));
}

CUnitAPI::CUnitAPI(const struct SSkirmishAICallback* clb, int sAIId)
		: sAICallback(clb)
		, skirmishAIId(sAIId)
{
}

CUnitAPI::~CUnitAPI()
{
}

int CUnitAPI::GetCMDQueueSize(int unitId)
{
	return sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId);
}

int CUnitAPI::GetCMD(int unitId, int commandIdx)
{
	return sAICallback->Unit_CurrentCommand_getId(skirmishAIId, unitId, commandIdx);
}

bool CUnitAPI::HasQueuedCommand(int unitId, int commandId) const
{
    // Inspect the live queue, including factory build queues and later WAITs.
    // No frame memo: another owner can replace it in this very callback.
    // O(Q) worst case, one count callback for an empty queue, no allocation.
    // Covered against the real C ABI by guard_callback_test.cpp.
    const int count = sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId);
    if (count < 0) return true; // failed observation must not suppress recovery
    for (int index = 0; index < count; ++index)
        if (sAICallback->Unit_CurrentCommand_getId(skirmishAIId, unitId, index) == commandId) return true;
    return false;
}

bool CUnitAPI::HasGuardIntent(int unitId, int targetId, int frame) const
{
	const int count = sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId);
	return guard::HasIntent(count, targetId, frame, [&](int i) {
		guard::Command c;
		const int id = sAICallback->Unit_CurrentCommand_getId(skirmishAIId, unitId, i);
		if (id != CMD_GUARD && id != CMD_REPAIR && id != CMD_MOVE) return c;
		const int options = sAICallback->Unit_CurrentCommand_getOptions(skirmishAIId, unitId, i);
		c.timeout = sAICallback->Unit_CurrentCommand_getTimeOut(skirmishAIId, unitId, i);
		// One bounded copy detects both single-target and malformed/area orders.
		// The C API returns the copied count, not the full size with this buffer.
		float params[4] = {};
		const int n = sAICallback->Unit_CurrentCommand_getParams(skirmishAIId, unitId, i, params, 4);
		if (id == CMD_GUARD || id == CMD_REPAIR) {
			c.kind = id == CMD_GUARD ? guard::Command::Kind::GUARD : guard::Command::Kind::REPAIR;
			const int mask = SHIFT_KEY | (id == CMD_REPAIR ? INTERNAL_ORDER : 0);
			c.valid = n == 1 && std::isfinite(params[0]) && params[0] >= 0.f
				&& (options & ~mask) == 0;
			c.target = params[0];
		} else {
			c.kind = guard::Command::Kind::MOVE;
			const bool internal = (options & INTERNAL_ORDER) != 0;
			const bool clearance = options == RIGHT_MOUSE_KEY && c.timeout != INT_MAX;
			c.valid = n == 3 && (internal || clearance)
				&& std::isfinite(params[0]) && std::isfinite(params[1]) && std::isfinite(params[2]);
		}
		return c;
	});
}

bool CUnitAPI::HasRouteIntent(int unitId, const std::vector<routecommand::Command>& issued, int frame) const
{
    const int count = sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId);
    return routecommand::LiveSuffix(issued, count, frame, [&](int i, routecommand::Command& c) {
        c.id = sAICallback->Unit_CurrentCommand_getId(skirmishAIId, unitId, i);
        c.options = sAICallback->Unit_CurrentCommand_getOptions(skirmishAIId, unitId, i);
        c.timeout = sAICallback->Unit_CurrentCommand_getTimeOut(skirmishAIId, unitId, i);
        float params[4];
        if (sAICallback->Unit_CurrentCommand_getParams(skirmishAIId,unitId,i,params,4) != 3) return false;
        c.x=params[0]; c.y=params[1]; c.z=params[2];
        return true;
    });
}

} /* namespace circuit */
