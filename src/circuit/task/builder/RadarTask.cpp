/*
 * RadarTask.cpp
 *
 *  Created on: Jan 31, 2015
 *      Author: rlcevg
 */

#include "task/builder/RadarTask.h"
#include "module/CommanderControl.h"
#include "module/TaskModule.h"
#include "CircuitAI.h"
#include "unit/CircuitDef.h"
#include "util/Utils.h"

namespace circuit {

using namespace springai;

CBRadarTask::CBRadarTask(ITaskModule* mgr, Priority priority,
						 CCircuitDef* buildDef, const AIFloat3& position,
						 SResource cost, float shake, int timeout)
		: ISensorTask(mgr, priority, [](CCircuitDef* cdef) { return cdef->IsRadar(); },
				buildDef, position, BuildType::RADAR, cost, shake, timeout)
{
}

CBRadarTask::CBRadarTask(ITaskModule* mgr)
		: ISensorTask(mgr, [](CCircuitDef* cdef) { return cdef->IsRadar(); }, BuildType::RADAR)
{
}

CBRadarTask::~CBRadarTask()
{
}

bool CBRadarTask::CanAssignTo(CCircuitUnit* unit) const
{
	if (!ISensorTask::CanAssignTo(unit)) return false;
	// Admission only: never abandon a nanoframe or a worker's live claim
	// because coverage changed while it was travelling/building. The shared
	// commander snapshot amortizes queue candidates; no new polling or orders.
	return target != nullptr || units.count(unit) != 0
			|| manager->GetCircuit()->GetCommanderControl()->CanStartRadar(unit);
}

} // namespace circuit
