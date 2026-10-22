/*
 * SpringUnit.h
 *
 *  Created on: Jul 20, 2026
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_SPRING_SPRINGUNIT_H_
#define SRC_CIRCUIT_SPRING_SPRINGUNIT_H_

#include <vector>
#include "spring/RouteCommand.h"

struct SSkirmishAICallback;

namespace circuit {

class CUnitAPI final {
public:
	CUnitAPI(const struct SSkirmishAICallback* clb, int sAIId);
	~CUnitAPI();

	int GetCMDQueueSize(int unitId);
	int GetCMD(int unitId, int commandIdx = 0);
    bool HasQueuedCommand(int unitId, int commandId) const;
    bool HasRouteIntent(int unitId, const std::vector<routecommand::Command>& issued, int frame) const;
	bool HasGuardIntent(int unitId, int targetId, int frame) const;
	// Callback-thread snapshots, without allocating per-unit C++ wrappers.
	// The buffer retains MAX_UNITS elements; only the returned prefix is valid.
	int GetFriendlyUnitIds(std::vector<int>& buffer) const;
	void GetPosition(int unitId, float* position) const;
	void GetVelocity(int unitId, float* velocity) const;
	float GetCombatHealth(int unitId) const;
    // Caller MUST establish current LOS (or own/allied ownership) first.
    int GetVisibleWeaponReload(int unitId,int weaponId) const;
    bool IsActiveSensor(int unitId) const; // own/allied or current LOS only

private:
	const struct SSkirmishAICallback* sAICallback;
	int skirmishAIId;
};

} /* namespace circuit */

#endif /* SRC_CIRCUIT_SPRING_SPRINGUNIT_H_ */
