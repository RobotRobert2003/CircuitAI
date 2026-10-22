#include "task/builder/CommanderTask.h"
#include "module/TaskModule.h"
#include "module/CommanderControl.h"
#include "unit/CircuitUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "util/Performance.h"

namespace circuit {
CCommanderTask::CCommanderTask(ITaskModule* manager,IUnitTask* previous)
    : IFighterTask(manager,FightType::DEFEND,1.f,-1),previous(previous) {
    if(previous) previous->AddRef();
}
CCommanderTask::~CCommanderTask() { if(previous) previous->Release(); }
void CCommanderTask::AssignTo(CCircuitUnit* unit) {
    // Do not call IFighterTask::AssignTo: its generic DGun action would be a
    // second command owner. This task owns no generic fighter side sets.
    oldFire=unit->GetRequestedFireState(); oldMove=unit->GetRequestedMoveState();
    oldCloak=unit->GetUnit()->IsCloaked();
    IUnitTask::AssignTo(unit);
}
void CCommanderTask::Restore(CCircuitUnit* unit) {
    if(unit->IsDead() || unit->IsDestroying()) return;
    TRY_UNIT(manager->GetCircuit(),unit,
        unit->TrySetFireState(static_cast<CCircuitDef::FireT>(oldFire));
        unit->TrySetMoveState(static_cast<CCircuitDef::MoveT>(oldMove));
        unit->CmdCloak(oldCloak);
    )
}
void CCommanderTask::Stop(bool done) {
    for(auto* unit:units) if(!unit->IsDead()) Restore(unit);
    IUnitTask::Stop(done);
}
void CCommanderTask::RemoveAssignee(CCircuitUnit* unit) {
    Restore(unit);
    IUnitTask::RemoveAssignee(unit);
    if(units.empty()) manager->AbortTask(this);
}
bool CCommanderTask::ForgetUnit(CCircuitUnit* unit) {
    const bool removed=IUnitTask::ForgetUnit(unit);
    if(removed && units.empty()) manager->AbortTask(this);
    return removed;
}
void CCommanderTask::OnUnitDestroyed(CCircuitUnit* unit,CEnemyInfo*) { ForgetUnit(unit); }
void CCommanderTask::OnUnitMoveFailed(CCircuitUnit* unit) {
    manager->GetCircuit()->GetCommanderControl()->MoveFailed(unit->GetId());
}
void CCommanderTask::Resume(CCircuitUnit* unit) {
    performance::Scope measured(manager->GetCircuit(),performance::COMMANDER_HANDOVER);
    // Manager may release this task later in the same scheduler cycle. The
    // prior task stays retained until this object is actually destroyed.
    // Wait/idle tasks do not necessarily emit a replacement command. Do not
    // leave the combat escape route running under their restored ownership.
    TRY_UNIT(manager->GetCircuit(),unit,unit->CmdStop();)
    if(previous && !previous->IsDead() && previous->GetManager()==manager
        && !previous->IsExternalControlled() && previous->CanAssignTo(unit)) {
        manager->AssignTask(unit,previous);
    } else RemoveAssignee(unit);
}
void CCommanderTask::Handover(CCircuitUnit* unit) {
    performance::Scope measured(manager->GetCircuit(),performance::COMMANDER_HANDOVER);
    TRY_UNIT(manager->GetCircuit(),unit,unit->CmdStop();)
    RemoveAssignee(unit);
}
}
