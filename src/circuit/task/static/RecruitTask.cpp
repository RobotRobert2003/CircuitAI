/*
 * RecruitTask.cpp
 *
 *  Created on: Sep 11, 2014
 *      Author: rlcevg
 */

#include "task/static/RecruitTask.h"
#include "module/EconomyManager.h"
#include "module/FactoryManager.h"
#include "terrain/TerrainManager.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitDef.h"
#include "unit/action/DGunAction.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringUnit.h"

#include "AISCommands.h"

namespace circuit {

using namespace springai;

CRecruitTask::CRecruitTask(ITaskModule* mgr, Priority priority,
						   CCircuitDef* buildDef, const AIFloat3& position,
						   RecruitType type, float radius)
		: IBuilderTask(mgr, priority, buildDef, position, Type::FACTORY, BuildType::RECRUIT, {0.f, 0.f}, 0.f, -1)
		, recruitType(type)
		, sqradius(radius * radius)
{
}

CRecruitTask::~CRecruitTask()
{
}

bool CRecruitTask::CanAssignTo(CCircuitUnit* unit) const
{
	if (!unit->IsProductionEnabled()) return false;
	// D-216: completion temporarily clears target while engine repeat continues.
	// A nearby idle lab must not adopt that live pump's task in this window:
	// one target pointer and one script owner cannot represent two factories.
	// Ordinary recruitment retains its existing assignment semantics.
	if (repeat && !units.empty() && units.find(unit) == units.end()) return false;
	return (target == nullptr) && unit->GetCircuitDef()->CanBuild(buildDef) &&
		   (position.SqDistance2D(unit->GetPos(manager->GetCircuit()->GetLastFrame())) <= sqradius);
}

void CRecruitTask::AssignTo(CCircuitUnit* unit)
{
	IUnitTask::AssignTo(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	ShowAssignee(unit);
	if (!geom::is_valid(position)) {
		position = unit->GetPos(circuit->GetLastFrame());
	}

	if (unit->HasDGun()) {
		unit->PushDGunAct(new CDGunAction(unit, unit->GetDGunRange()));
	}
}

void CRecruitTask::Start(CCircuitUnit* unit)
{
	Execute(unit);
}

void CRecruitTask::Update()
{
	if (units.empty()) {
		return;
	}

	CCircuitAI* circuit = manager->GetCircuit();
	CEconomyManager* economyMgr = circuit->GetEconomyManager();

	const bool isEnergyEmpty = economyMgr->IsEnergyEmpty();
	for (CCircuitUnit* unit : units) {
		TRY_UNIT(circuit, unit,
			unit->CmdWait(isEnergyEmpty);
		)
	}
	if (isEnergyEmpty) {
		return;
	}

	bool hasMetal = economyMgr->GetAvgMetalIncome() * 2.0f > economyMgr->GetMetalPull();
	if (State::DISENGAGE == state) {
		if (hasMetal) {
			state = State::ROAM;  // Not wait
			for (CCircuitUnit* unit : units) {
				TRY_UNIT(circuit, unit,
					unit->CmdPriority(ClampPriority());
					unit->CmdBARPriority(ClampPriority());
				)
			}
		}
	} else {
		if (!hasMetal) {
			state = State::DISENGAGE;  // Wait
			for (CCircuitUnit* unit : units) {
				TRY_UNIT(circuit, unit,
					unit->CmdPriority(0);
					unit->CmdBARPriority(0);
				)
			}
		}
	}
}

void CRecruitTask::Finish()
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int buildDelay = circuit->GetEconomyManager()->GetBuildDelay();
	// The engine consumes a naturally completed single build itself. Removing
	// it here emits a second idle callback while the replacement is in flight,
	// and can cancel that replacement when it has the same negative UnitDef ID.
	// Retain only the verified single-product queue; repeats, cancellations,
	// unexpected queues and difficulty pauses keep their original cleanup.
	bool naturalCompletion = completionRefill && !repeat && buildDelay <= 0
		&& target != nullptr && target->IsFinished() && units.size() == 1;
	if (naturalCompletion) {
		const int id = (*units.begin())->GetId();
		auto* api = circuit->GetUnitAPI();
		const int count = api->GetCMDQueueSize(id);
		naturalCompletion = count == 0 || (count == 1 && api->GetCMD(id) == -buildDef->GetId());
	}
	if (naturalCompletion) SetTarget(nullptr);
	else Cancel();

	if (buildDelay > 0) {
		// NOTE: force-stop as there could be bug present that queues more than 1 unit
		IUnitTask* task = circuit->GetFactoryManager()->Enqueue(TaskS::Wait(true, buildDelay));
		decltype(units) tmpUnits = units;
		for (CCircuitUnit* unit : tmpUnits) {
			manager->AssignTask(unit, task);
		}
	}
}

void CRecruitTask::Cancel()
{
	if (target != nullptr) {
		SetTarget(nullptr);
	}

	CCircuitAI* circuit = manager->GetCircuit();
	CUnitAPI* unitAPI = circuit->GetUnitAPI();
	for (CCircuitUnit* unit : units) {
		// Clear build-queue
		if (repeat) {
			TRY_UNIT(circuit, unit, unit->GetUnit()->SetRepeat(false);)
		}
		int cmdSize = unitAPI->GetCMDQueueSize(unit->GetId());
		std::vector<float> params;
		params.reserve(cmdSize);
		for (int commandIdx = 0; commandIdx < cmdSize; ++commandIdx) {
			int cmdId = unitAPI->GetCMD(unit->GetId(), commandIdx);
			if (cmdId < 0) {
				params.push_back(cmdId);
			}
		}
		TRY_UNIT(circuit, unit,
			unit->CmdRemove(std::move(params), UNIT_COMMAND_OPTION_ALT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
		)
	}
}

bool CRecruitTask::Execute(CCircuitUnit* unit)
{
	if (!unit->IsProductionEnabled()) return false;
	executors.insert(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	TRY_UNIT(circuit, unit,
		unit->CmdPriority(ClampPriority());
		unit->CmdBARPriority(ClampPriority());
	)
	const int frame = circuit->GetLastFrame();

	if (unit->GetCircuitDef()->IsHub()) {
		AIFloat3 pos = unit->GetPos(frame);
		const float size = DEFAULT_SLACK / 2;
		switch (unit->GetUnit()->GetBuildingFacing()) {
			default:
			case UNIT_FACING_SOUTH: {  // z++
				pos.z += size;
			} break;
			case UNIT_FACING_EAST: {  // x++
				pos.x += size;
			} break;
			case UNIT_FACING_NORTH: {  // z--
				pos.z -= size;
			} break;
			case UNIT_FACING_WEST: {  // x--
				pos.x -= size;
			} break;
		}
		buildPos = circuit->GetTerrainManager()->FindBuildSite(buildDef, pos, unit->GetCircuitDef()->GetBuildDistance(), UNIT_NO_FACING, true);
//		buildPos = circuit->GetTerrainManager()->FindSpringBuildSite(buildDef, pos, unit->GetCircuitDef()->GetBuildDistance(), UNIT_NO_FACING);
	} else {
		// factory
		buildPos = unit->GetPos(frame);
	}

	if (geom::is_valid(buildPos)) {
		TRY_UNIT(circuit, unit,
			if (repeat) unit->GetUnit()->SetRepeat(true);
			unit->CmdBuild(buildDef, buildPos, UNIT_NO_FACING, 0, repeat ? INT_MAX : frame + FRAMES_PER_SEC * 10);
			lastBuildCommandFrame = frame;
		)
	} else {
		manager->AbortTask(this);
		return false;
	}
	return true;
}

void CRecruitTask::OnUnitIdle(CCircuitUnit* unit)
{
	if (completionRefill) {
		// Recoil can finish the old product and report its factory idle later in
		// the SAME frame, before our replacement command has crossed the network.
		// This is an in-flight dispatch, not a rate limit. After this frame an
		// empty/unstarted task recovers normally. A live target already proves
		// that the current owner is building; don't append duplicate recruits.
		if (unit->GetTask() != this || IsDead()) return;
		if (lastBuildCommandFrame == manager->GetCircuit()->GetLastFrame()
			|| (target != nullptr && !target->IsDead() && !target->IsFinished())) return;
	}
	if (repeat) {
		// Engine idle callbacks can race a repeat's next build. Repair an empty
		// queue only; never add another copy of the repeating build command.
		auto* api = manager->GetCircuit()->GetUnitAPI();
		const int size = api->GetCMDQueueSize(unit->GetId());
		for (int i = 0; i < size; ++i) if (api->GetCMD(unit->GetId(), i) < 0) return;
	}
	Start(unit);
}

void CRecruitTask::RemoveAssignee(CCircuitUnit* unit)
{
	if (repeat && !unit->IsDead()) {
		// Reassignment/player control can remove the worker without stopping the
		// old task first. Remove only this owner's repeated build, not a player's
		// unrelated queue. The normal Cancel path still owns whole-queue cleanup.
		TRY_UNIT(manager->GetCircuit(), unit,
			unit->GetUnit()->SetRepeat(false);
			unit->CmdRemove({-float(buildDef->GetId())}, UNIT_COMMAND_OPTION_ALT_KEY | UNIT_COMMAND_OPTION_CONTROL_KEY);
		)
	}
	IBuilderTask::RemoveAssignee(unit);
	if (repeat && units.empty()) manager->AbortTask(this);
}

void CRecruitTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	if (unit->GetHealthPercent() < unit->GetCircuitDef()->GetSelfDHP()) {
		unit->CmdSelfD(true);
	}
}

void CRecruitTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	RemoveAssignee(unit);
}

void CRecruitTask::SetTarget(CCircuitUnit* unit)
{
	for (CCircuitUnit* worker : units) {
		if (!worker->GetCircuitDef()->IsHub()) {  // do not replace or remove blocker
			buildPos = -RgtVector;
			break;
		}
	}
	IBuilderTask::SetTarget(unit);
    static_cast<CFactoryManager*>(manager)->RefreshPendingRecruit(this);
}

void CRecruitTask::Dead()
{
    IUnitTask::Dead();
    static_cast<CFactoryManager*>(manager)->RefreshPendingRecruit(this);
}

} // namespace circuit
