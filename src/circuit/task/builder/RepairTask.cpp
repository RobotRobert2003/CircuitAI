/*
 * RepairTask.cpp
 *
 *  Created on: Jan 29, 2015
 *      Author: rlcevg
 */

#include "task/builder/RepairTask.h"
#include "task/RetreatTask.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "unit/action/TravelAction.h"
#include "CircuitAI.h"
#include "module/CommanderControl.h"
#include "util/Utils.h"
#include "spring/CustomCommand.h"
#include "spring/SpringCallback.h"
#include "spring/SpringUnit.h"
#include "Log.h"
#include <array>

namespace circuit {

using namespace springai;

CBRepairTask::CBRepairTask(ITaskModule* mgr, Priority priority, CAllyUnit* target, int timeout)
		: IRepairTask(mgr, priority, Type::BUILDER, target, timeout)
{
	static_cast<CBuilderManager*>(mgr)->MarkRepairUnit(target->GetId(), this);
}

CBRepairTask::CBRepairTask(ITaskModule* mgr)
		: IRepairTask(mgr, Type::BUILDER)
{
}

CBRepairTask::~CBRepairTask()
{
}

bool CBRepairTask::CanAssignTo(CCircuitUnit* unit) const
{
	if (unit->GetCircuitDef()->IsRoleComm() && unit->GetId() != invitedCommander) {
		return false;
	}
	if(IsStationaryCommander(unit)) {
        auto* ai=manager->GetCircuit();auto* ally=ai->GetFriendlyUnit(targetId);
        return ally && ally->GetId()!=unit->GetId() && unit->GetCircuitDef()->IsAbleToRepair()
            && !ally->GetUnit()->IsBeingBuilt()
            && ally->GetPos(ai->GetLastFrame()).SqDistance(unit->GetPos(ai->GetLastFrame()))
                <=SQUARE(unit->GetCircuitDef()->GetBuildDistance());
    }
	return IRepairTask::CanAssignTo(unit);
}

void CBRepairTask::Start(CCircuitUnit* unit)
{
	IRepairTask::Start(unit);
	if (targetId != -1) {
		Update(unit);
	}
}

// Engine repair-with-area rejects a target outside this fixed local disc
// before MoveInBuildRange. AI positions are model midpoints, whereas the
// engine repair-area check uses base positions: retain a 32-elmo inset rather
// than pinning an exact midpoint (which repeatedly cancelled every order).
// No travel action is activated; shared ordinary repair assignees are unchanged.
void CBRepairTask::UpdateStationary(CCircuitUnit* unit)
{
    auto* ai=manager->GetCircuit();
    auto* ally=ai->GetFriendlyUnit(targetId);
    const int frame=ai->GetLastFrame();
    const auto here=unit->GetPos(frame);
    const float reach=unit->GetCircuitDef()->GetBuildDistance()-32.f;
    if(!ally || ally->GetUnit()->IsBeingBuilt()
        || ally->GetUnit()->GetHealth()>=ally->GetUnit()->GetMaxHealth()
        || here.SqDistance(ally->GetPos(frame))>reach*reach
        || static_cast<CBuilderManager*>(manager)->IsReclaimUnit(ally)) {
        TRY_UNIT(ai,unit,unit->CmdStop();)
        RemoveAssignee(unit);return;
    }
    if(ai->GetUnitAPI()->GetCMDQueueSize(unit->GetId())>0
        && unit->GetTaskState()==CCircuitUnit::ETaskState::EXECUTE) return;
    std::array<float,5> params={float(targetId),here.x,here.y,here.z,reach-100.f};
    TRY_UNIT(ai,unit,
        unit->CmdStop();
        SendCustomCommand(ai->GetSkirmishAIId(),unit->GetId(),40,params,0,frame+30*FRAMES_PER_SEC);
    )
    unit->SetTaskState(CCircuitUnit::ETaskState::EXECUTE);
    ai->LOG("[CommanderRepair] unit=%i target=%i stationary=1",unit->GetId(),targetId);
}

void CBRepairTask::OnUnitIdle(CCircuitUnit* unit)
{
	// D-211: allied repairs deliberately store only targetId (SetRepTarget).
	// Resolve it just as Execute/Reevaluate do; an ally can disappear before
	// the idle event. The 8v8 recovery fixture exercises cross-team repair.
	CAllyUnit* repTarget = target != nullptr ? target : manager->GetCircuit()->GetFriendlyUnit(targetId);
	if (repTarget == nullptr) {
		manager->AbortTask(this);
		return;
	}
	Unit* u = repTarget->GetUnit();
	if (u->GetHealth() < u->GetMaxHealth()) {
		// unit stuck or event order fail
		RemoveAssignee(unit);
	} else {
		// task finished
		manager->DoneTask(this);
	}
}

void CBRepairTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
    if(manager->GetCircuit()->GetCommanderControl()->Jammed(unit)) return;
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitDef* cdef = unit->GetCircuitDef();
	const float healthPerc = unit->GetHealthPercent();
	if ((healthPerc > cdef->GetRetreat()) && !unit->IsDisarmed(frame)) {
		if (healthPerc < cdef->GetSelfDHP()) {
			unit->CmdSelfD(true);
		}
		return;
	}

	CRetreatTask* task = manager->EnqueueRetreat();
	manager->AssignTask(unit, task);
}

bool CBRepairTask::Reevaluate(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	// FIXME: Replace const 1000.0f with build time?
	if ((cost.metal > 1000.f)
		&& ((economyMgr->GetAvgMetalIncome() < savedIncome.metal * 0.6f)
			|| (economyMgr->GetAvgEnergyIncome() < savedIncome.energy * 0.6f)))
	{
		manager->AbortTask(this);
		return false;
	}

	CAllyUnit* repTarget = (target != nullptr) ? target : circuit->GetFriendlyUnit(targetId);
	if ((repTarget != nullptr) && (repTarget->GetUnit()->GetHealth() < repTarget->GetUnit()->GetMaxHealth())
		&& !static_cast<CBuilderManager*>(manager)->IsReclaimUnit(repTarget))  // marked for reclaim since we started
	{
		buildPos = repTarget->GetPos(circuit->GetLastFrame());
	} else {
		manager->AbortTask(this);
		return false;
	}
	return true;
}

bool CBRepairTask::Load(std::istream& is)
{
	IRepairTask::Load(is);

	CBuilderManager* builderMgr = static_cast<CBuilderManager*>(manager);
	if (target != nullptr) {
		IUnitTask* task = builderMgr->GetRepairTask(target->GetId());
		if (task != nullptr) {
			// FIXME: Units added before Load() by UnitCreated() may create repair task
			builderMgr->AbortTask(task);
		}
		builderMgr->MarkRepairUnit(target->GetId(), this);
	}
	return true;
}

} // namespace circuit
