/*
 * TaskModule.cpp
 *
 *  Created on: Jan 20, 2015
 *      Author: rlcevg
 */

#include "module/TaskModule.h"
#include "module/BuilderManager.h"
#include "script/TaskModuleScript.h"
#include "task/NilTask.h"
#include "task/IdleTask.h"
#include "task/PlayerTask.h"
#include "task/RetreatTask.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitDef.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include "util/Profiler.h"

namespace circuit {

ITaskModule::ITaskModule(CCircuitAI* circuit, IScript* script)
		: IModule(circuit, script)
		, nilTask(nullptr)
		, idleTask(nullptr)
		, playerTask(nullptr)
		, updateIterator(0)
		, metalPull(0.f)
{
	Init();
}

ITaskModule::~ITaskModule()
{
	// Units and script handles can outlive manager membership. Release the
	// owner's reference, never bypass the shared task lifetime with delete.
	nilTask->ClearRelease();
	idleTask->ClearRelease();
	playerTask->ClearRelease();

	for (IUnitTask* task : updateTasks) {
		task->ClearRelease();
	}
}

void ITaskModule::Init()
{
	nilTask = new CNilTask(this);
	idleTask = new CIdleTask(this);
	playerTask = new CPlayerTask(this);
}

void ITaskModule::Release()
{
	// NOTE: Release expected to be called on CCircuit::Release.
	//       It doesn't stop scheduled GameTasks for that reason.
	for (IUnitTask* task : updateTasks) {
		AbortTask(task);
		// NOTE: Do not delete task as other AbortTask may ask for it
	}
	for (IUnitTask* task : updateTasks) {
		task->ClearRelease();
	}
	updateTasks.clear();
}

void ITaskModule::AssignTask(CCircuitUnit* unit, IUnitTask* task)
{
	if (unit->GetTask()->IsEnemyReclaim() && task->GetType() != IUnitTask::Type::PLAYER) {
		if (task != unit->GetTask() && task->GetAssignees().empty()) task->GetManager()->DiscardUnusedTask(task);
		return;
	}
	{
		// D-070 diagnostics: a task swap of an experimental builder
		CBuilderManager* bm = dynamic_cast<CBuilderManager*>(this);
		if ((bm != nullptr) && bm->IsExperimentalBuild() && (unit->GetCircuitDef() != nullptr)) {
			GetCircuit()->LOG("EXP: swap: %s(%i) from task type %i to task type %i", unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(),
					int(unit->GetTask()->GetType()), int(task->GetType()));
		}
	}
	unit->GetTask()->RemoveAssignee(unit);
	task->AssignTo(unit);
	task->Start(unit);
}

void ITaskModule::AssignTask(CCircuitUnit* unit)
{
	if (unit->GetTask()->IsEnemyReclaim()) return;
	IUnitTask* task = MakeTask(unit);
	if (task == nullptr) {
		return;
	}
	if (task->GetManager() != this) {
		// Script returned a task owned by another manager (seen: a factory Wait for a
		// nuke silo). IUnitTask::AssignTo only removes the unit from the task owner's
		// idle list, so the unit would stay idle here, be assigned a second task later
		// and, once the foreign task stops, be re-parented while the second task still
		// lists it. That second task then dereferences the unit after it is freed.
		GetCircuit()->LOG("ITaskModule::AssignTask: refused task of another manager for %s(%i); unit stays idle",
				unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId());
		return;
	}
	task->AssignTo(unit);
}

void ITaskModule::DequeueTask(IUnitTask* task, bool done)
{
	task->Dead();
	TaskRemoved(task, done);
	task->Stop(done);
}

void ITaskModule::AbortTask(IUnitTask* task)
{
	// D-216: idle/nil/player are manager-owned shared states, not cancellable
	// work. TECH retiring an already-idle opening lab used to stop the shared
	// idle task, orphaning every other idle factory until a new event re-added
	// it. Idempotence also protects persistent recruits during reassignment.
	if (task == nullptr || task == idleTask || task == nilTask || task == playerTask || task->IsDead()) return;
	DequeueTask(task, false);
}

IUnitTask* ITaskModule::MakeTask(CCircuitUnit* unit)
{
	return static_cast<ITaskModuleScript*>(script)->MakeTask(unit);  // DefaultMakeTask
}

void ITaskModule::TaskAdded(IUnitTask* task)
{
	static_cast<ITaskModuleScript*>(script)->TaskAdded(task);
}

void ITaskModule::TaskRemoved(IUnitTask* task, bool done)
{
	static_cast<ITaskModuleScript*>(script)->TaskRemoved(task, done);
}

int ITaskModule::ForgetUnitEverywhere(CCircuitUnit* unit)
{
	int n = 0;
	for (IUnitTask* task : updateTasks) {
		if ((task != nullptr) && task->ForgetUnit(unit)) {
			++n;
		}
	}
	for (IUnitTask* task : {static_cast<IUnitTask*>(nilTask), static_cast<IUnitTask*>(idleTask), static_cast<IUnitTask*>(playerTask)}) {
		if ((task != nullptr) && task->ForgetUnit(unit)) {
			++n;
		}
	}
	return n;
}

void ITaskModule::AssignPlayerTask(CCircuitUnit* unit)
{
	AssignTask(unit, playerTask);
}

void ITaskModule::Resurrected(CCircuitUnit* unit)
{
	CRetreatTask* task = EnqueueRetreat();
	if (task != nullptr) {
		AssignTask(unit, task);
	}
}

void ITaskModule::UpdateIdle()
{
	ZoneScoped;

	idleTask->Update();
}

void ITaskModule::Update()
{
	ZoneScoped;

	if (updateIterator >= updateTasks.size()) {
		updateIterator = 0;
	}

	int lastFrame = GetCircuit()->GetLastFrame();
	// stagger the Update's
	unsigned int n = (updateTasks.size() / TEAM_SLOWUPDATE_RATE) + 1;

	while ((updateIterator < updateTasks.size()) && (n != 0)) {
		IUnitTask* task = updateTasks[updateIterator];
		if (task->IsDead()) {
			updateTasks[updateIterator] = updateTasks.back();
			updateTasks.pop_back();
			task->ClearRelease();  // delete task;
		} else {
			// NOTE: IFighterTask.timeout = 0
			int frame = task->GetLastTouched();
			int timeout = task->GetTimeout();
			if ((frame != -1) && (timeout > 0) && (lastFrame - frame >= timeout)) {
				AbortTask(task);
			} else {
				task->Update();
			}
			++updateIterator;
			n--;
		}
	}
}

} // namespace circuit
