/*
 * IdleTask.cpp
 *
 *  Created on: Jan 13, 2015
 *      Author: rlcevg
 */

#include "task/IdleTask.h"
#include "task/RetreatTask.h"
#include "module/TaskModule.h"
#include "unit/CircuitUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include <vector>

namespace circuit {

CIdleTask::CIdleTask(ITaskModule* mgr)
		: IUnitTask(mgr, Priority::NORMAL, Type::IDLE, -1)
		, updateSlice(0)
{
}

CIdleTask::~CIdleTask()
{
}

void CIdleTask::AssignTo(CCircuitUnit* unit)
{
	unit->SetTask(this);
	units.insert(unit);
}

void CIdleTask::RemoveAssignee(CCircuitUnit* unit)
{
	if (units.erase(unit) > 0) {  // double call of this function is OK
		updateUnits.erase(unit);
	}

	unit->ClearAct();
}

void CIdleTask::Start(CCircuitUnit* unit)
{
	// NOTE: may happen when PathRequest wasn't finished in time,
	//       then manager->AssignTask(ass) won't do anything and this->Start() is invoked.
	//       @see CBuilderManager::DefaultMakeTask => return nullptr;
//	assert(false);
}

void CIdleTask::Update()
{
	if (updateUnits.empty()) {
		updateUnits = units;  // copy units
		updateSlice = updateUnits.size() / TEAM_SLOWUPDATE_RATE;
	}

	// D-114 crash (build93, F53834): AssignTask runs the script's rule table, which
	// can re-task OTHER idle units (a retired factory, turrets pulled onto a
	// reclaim); RemoveAssignee then erased them from updateUnits under the running
	// iterator. The slice is taken out of the set first, and each unit is assigned
	// only while it is still ours to assign.
	const int frame = manager->GetCircuit()->GetLastFrame();
	std::vector<CCircuitUnit*> batch;
	for (auto it = updateUnits.begin(); it != updateUnits.end();) {
		CCircuitUnit* ass = *it;

		// get rid of delayed by engine UnitIdle event from previous task
		if (frame < ass->GetTaskFrame() + 20) {
			++it;
			continue;
		}

		it = updateUnits.erase(it);
		batch.push_back(ass);

		if (batch.size() >= updateSlice) {
			break;
		}
	}

	for (CCircuitUnit* ass : batch) {
		if (ass->IsDead() || (units.find(ass) == units.end())) {
			continue;  // left the idle task while an earlier unit was assigned
		}
		if (ass->GetTask() != this) {
			// Never restart another manager's active task through a stale idle
			// membership. Erase bookkeeping directly: RemoveAssignee clears actions
			// and would disrupt the legitimate owner we are protecting.
			units.erase(ass);
			continue;
		}
		manager->AssignTask(ass);  // should RemoveAssignee() on AssignTo()
		ass->GetTask()->Start(ass);
	}
}

void CIdleTask::Stop(bool done)
{
	// NOTE: Should not be ever called, except on AI termination
	assert(false);
	units.clear();
	updateUnits.clear();
}

void CIdleTask::OnUnitIdle(CCircuitUnit* unit)
{
	// Do nothing. Unit is already idling.
}

void CIdleTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	const float healthPerc = unit->GetHealthPercent();
	if (healthPerc < unit->GetCircuitDef()->GetRetreat()) {
		CRetreatTask* task = manager->EnqueueRetreat();
		if (task != nullptr) {
			task->AssignTo(unit);
			task->Start(unit);
		}
	} else if (healthPerc < unit->GetCircuitDef()->GetSelfDHP()) {
		unit->CmdSelfD(true);
	}
}

void CIdleTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
}

} // namespace circuit
