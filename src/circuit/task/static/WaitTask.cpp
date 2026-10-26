/*
 * WaitTask.cpp
 *
 *  Created on: May 29, 2017
 *      Author: rlcevg
 */

#include "task/static/WaitTask.h"
#include "unit/CircuitUnit.h"
#include "module/TaskModule.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringUnit.h"

namespace circuit {

CSWaitTask::CSWaitTask(ITaskModule* mgr, bool stop, int timeout)
		: IWaitTask(mgr, stop, timeout)
{
}

CSWaitTask::~CSWaitTask()
{
}

void CSWaitTask::Start(CCircuitUnit* unit)
{
	IWaitTask::Start(unit);
	// Owner, 2026-10-26: a factory told to wait stops its lag-fallback repeat; a
	// product already started finishes once and is not built again
	if (unit->IsLagRepeat()) {
		TRY_UNIT(manager->GetCircuit(), unit, unit->GetUnit()->SetRepeat(false);)
	}
}

void CSWaitTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	if (unit->GetHealthPercent() < unit->GetCircuitDef()->GetSelfDHP()) {
		unit->CmdSelfD(true);
	}
}

} // namespace circuit
