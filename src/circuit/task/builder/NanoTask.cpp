/*
 * NanoTask.cpp
 *
 *  Created on: Jan 30, 2015
 *      Author: rlcevg
 */

#include "task/builder/NanoTask.h"
#include "module/TaskModule.h"
#include "map/ThreatMap.h"
#include "resource/MetalManager.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringMap.h"

#include "AISCommands.h"

namespace circuit {

using namespace springai;

CBNanoTask::CBNanoTask(ITaskModule* mgr, Priority priority,
					   CCircuitDef* buildDef, const AIFloat3& position,
					   SResource cost, float shake, int timeout)
		: IBuilderTask(mgr, priority, buildDef, position, Type::BUILDER, BuildType::NANO, cost, shake, timeout)
{
}

CBNanoTask::CBNanoTask(ITaskModule* mgr)
		: IBuilderTask(mgr, Type::BUILDER, BuildType::NANO)
{
}

CBNanoTask::~CBNanoTask()
{
}

bool CBNanoTask::Execute(CCircuitUnit* unit)
{
	executors.insert(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	TRY_UNIT(circuit, unit,
		unit->CmdPriority(ClampPriority());
	)

	const int frame = circuit->GetLastFrame();
	if (target != nullptr) {
		TRY_UNIT(circuit, unit,
			unit->CmdRepair(target, UNIT_CMD_OPTION, CmdTimeout(frame));
		)
		return true;
	}
	if (TryBuildCachedSite(unit)) return true;

	if (AdoptStandingFrame(unit)) return true;

	// Alter/randomize position
	AIFloat3 pos = (shake > .0f) ? geom::get_near_pos(position, shake) : position;

	circuit->GetThreatMap()->SetThreatType(unit);
	float searchRadius = buildDef->GetBuildDistance();
	FindBuildSite(unit, pos, searchRadius);

	if (geom::is_valid(buildPos)) {
		TRY_UNIT(circuit, unit,
			unit->CmdBuild(buildDef, buildPos, facing, 0, CmdTimeout(frame));
		)
	} else if (pinFailed) {
		manager->AbortTask(this);
		return false;
	} else {
		// Fallback to Guard/Assist/Patrol
		manager->FallbackTask(unit);
		return false;
	}
	return true;
}

} // namespace circuit
