/*
 * GuardTask.cpp
 *
 *  Created on: Jul 13, 2016
 *      Author: rlcevg
 */

#include "task/builder/GuardTask.h"
#include "module/BuilderManager.h"
#include "terrain/TerrainManager.h"  // Only for CorrectPosition
#include "spring/SpringUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "AISCommands.h"
#include "Command.h"
#include "Log.h"
#include "Sim/Units/CommandAI/Command.h"
#include <cstdlib>

namespace circuit {

CBGuardTask::CBGuardTask(ITaskModule* mgr, Priority priority, CCircuitUnit* vip, bool isInterrupt, int timeout)
		: IBuilderTask(mgr, priority, nullptr, vip->GetPos(mgr->GetCircuit()->GetLastFrame()),
					   Type::BUILDER, BuildType::GUARD, {0.f, 0.f}, 0.f, timeout)
		, vipId(vip->GetId())
		, isInterrupt(isInterrupt)
{
}

CBGuardTask::~CBGuardTask()
{
}

bool CBGuardTask::CanAssignTo(CCircuitUnit* unit) const
{
	return true;
}

void CBGuardTask::AssignTo(CCircuitUnit* unit)
{
	IBuilderTask::AssignTo(unit);

	CCircuitDef* cdef = unit->GetCircuitDef();
	if (IsTargetBuilder()) {
		if (cdef->IsAbleToAssist()) {
			static_cast<CBuilderManager*>(manager)->IncGuardCount();
		}
	} else if (cdef->IsBuilder()) {
		// not testing IsAbleToAssist as AddBuildPower applied only to IsBuilder in CBuilderManager
		static_cast<CBuilderManager*>(manager)->DelBuildPower(unit);
	}

	if (!isInterrupt) {
		lastTouched = manager->GetCircuit()->GetLastFrame();
	}
}

void CBGuardTask::RemoveAssignee(CCircuitUnit* unit)
{
	IBuilderTask::RemoveAssignee(unit);
	if (units.empty()) {
		manager->AbortTask(this);
	}

	CCircuitDef* cdef = unit->GetCircuitDef();
	if (IsTargetBuilder()) {
		if (cdef->IsAbleToAssist()) {
			static_cast<CBuilderManager*>(manager)->DecGuardCount();
		}
	} else if (cdef->IsBuilder()) {
		static_cast<CBuilderManager*>(manager)->AddBuildPower(unit);
	}
}

void CBGuardTask::Stop(bool done)
{
	const bool isVIPBuilder = IsTargetBuilder();
	for (CCircuitUnit* unit : units) {
		CCircuitDef* cdef = unit->GetCircuitDef();
		if (isVIPBuilder) {
			if (cdef->IsAbleToAssist()) {
				static_cast<CBuilderManager*>(manager)->DecGuardCount();
			}
		} else if (cdef->IsBuilder()) {
			static_cast<CBuilderManager*>(manager)->AddBuildPower(unit);
		}
	}

	IBuilderTask::Stop(done);
}

bool CBGuardTask::Execute(CCircuitUnit* unit)
{
	if (IsDead() || unit->GetTask() != this) return false;
	executors.insert(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	CCircuitUnit* vip = circuit->GetTeamUnit(vipId);
	if (vip != nullptr) {
		const int frame = circuit->GetLastFrame();
		const AIFloat3& vipPos = vip->GetPos(frame);
		const AIFloat3& unitPos = unit->GetPos(frame);
		TRY_UNIT(circuit, unit,
			unit->CmdPriority(ClampPriority());
			// Keep both assistance and the pending clearance MOVE intact. Priority
			// still updates; only an equivalent live GUARD is suppressed (D-223).
			if (KeepGuard(unit, "execute")) return true;
			short options = UNIT_CMD_OPTION;
			// FIXME: it's not "Smooth area" and is broken when waterlevel is changed
//			if (unit->GetCircuitDef()->IsAbleToRestore()) {
//				unit->GetUnit()->RestoreArea(vip->GetPos(circuit->GetLastFrame()), 128.f);
//				options = UNIT_COMMAND_OPTION_SHIFT_KEY;
//			}
			if ((unit->GetCircuitDef()->GetBuildDistance() > 80.f) && (vipPos.SqDistance2D(unitPos) < SQUARE(48.f))) {
				AIFloat3 pos = vipPos + (unitPos - vipPos).Normalize2D() * 64.f;
				CTerrainManager::CorrectPosition(pos);
				unit->CmdMoveTo(pos, options | UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + FRAMES_PER_SEC * 60);
				options = UNIT_COMMAND_OPTION_SHIFT_KEY;
			}
			unit->GetUnit()->Guard(vip->GetUnit(), options);
		)
	} else {
		manager->AbortTask(this);
		return false;
	}
	return true;
}

void CBGuardTask::OnUnitIdle(CCircuitUnit* unit)
{
	if (IsDead() || unit->GetTask() != this) return;
	CCircuitAI* circuit = manager->GetCircuit();
	CCircuitUnit* vip = circuit->GetTeamUnit(vipId);
	if (vip != nullptr) {
		TRY_UNIT(circuit, unit,
			if (KeepGuard(unit, "idle")) return;
			unit->GetUnit()->Guard(vip->GetUnit());
		)
	} else {
		manager->AbortTask(this);
	}
}

bool CBGuardTask::KeepGuard(CCircuitUnit* unit, const char* source) const
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	const bool keep = circuit->GetUnitAPI()->HasGuardIntent(unit->GetId(), vipId, frame);
	// Optional fixture diagnostics only. Normal games allocate no wrappers and
	// emit no per-order logs. The independent wrapper check audits every skip;
	// it deliberately does not replace the stricter prefix/options admission.
	static const bool verify = std::getenv("CIRCUIT_VERIFY_GUARD") != nullptr;
	if (verify) {
		if (keep) {
			bool found = false;
			struct Commands {
				std::vector<springai::Command*> values;
				~Commands() { utils::free_clear(values); }
			} commands{unit->GetUnit()->GetCurrentCommands()};
			for (auto* cmd : commands.values) {
				if (cmd->GetId() != CMD_GUARD || cmd->GetTimeOut() < frame) continue;
				const auto params = cmd->GetParams();
				found |= params.size() == 1 && params[0] == vipId;
			}
			if (!found) circuit->LOG("[INVARIANT] INV-163 suppressed guard absent: unit=%i target=%i", unit->GetId(), vipId);
		}
		circuit->LOG("GUARD: unit=%i target=%i source=%s action=%s", unit->GetId(), vipId, source, keep ? "keep" : "send");
	}
	return keep;
}

bool CBGuardTask::Reevaluate(CCircuitUnit* unit)
{
	if (!isInterrupt) {
		return true;
	}
	struct EvaluationScope {
		int& worker;
		int previous;
		~EvaluationScope() { worker = previous; }
	} scope{reevaluatingWorker, reevaluatingWorker};
	reevaluatingWorker = unit->GetId();
	return IBuilderTask::Reevaluate(unit);
}

bool CBGuardTask::IsTargetBuilder() const
{
	CCircuitUnit* vip = manager->GetCircuit()->GetTeamUnit(vipId);
	return (vip != nullptr) && vip->GetCircuitDef()->IsBuilder();
}

} // namespace circuit
