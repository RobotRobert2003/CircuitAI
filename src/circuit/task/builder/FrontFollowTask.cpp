#include "task/builder/FrontFollowTask.h"
#include "module/TaskModule.h"
#include "task/RetreatTask.h"
#include "unit/CircuitUnit.h"
#include "spring/SpringUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"

namespace circuit {
CFrontFollowTask::CFrontFollowTask(ITaskModule* manager,int target,float radius)
    :IWaitTask(manager,true,-1),target(target),radius(radius) {}
void CFrontFollowTask::Start(CCircuitUnit* unit) {
    TRY_UNIT(manager->GetCircuit(),unit,unit->CmdStop();)
    Follow(unit);
}
void CFrontFollowTask::OnUnitDamaged(CCircuitUnit* unit,CEnemyInfo*) {
    if(unit->GetHealthPercent()>unit->GetCircuitDef()->GetRetreat() && !unit->IsDisarmed(manager->GetCircuit()->GetLastFrame())) return;
    manager->AssignTask(unit,manager->EnqueueRetreat());
}
void CFrontFollowTask::OnUnitIdle(CCircuitUnit* unit) { Follow(unit); }
void CFrontFollowTask::Update() {
    auto* ai=manager->GetCircuit();
    if(ai->GetLastFrame()<next) return;
    next=ai->GetLastFrame()+FRAMES_PER_SEC;
    if(!ai->GetTeamUnit(target)) { manager->AbortTask(this);return; }
    for(auto* unit:units) if(unit->GetTask()==this) Follow(unit);
}
void CFrontFollowTask::Follow(CCircuitUnit* unit) {
    auto* ai=manager->GetCircuit();
    auto* leader=ai->GetTeamUnit(target);
    if(!leader || unit->GetTask()!=this) return;
    const int frame=ai->GetLastFrame();
    const auto at=leader->GetPos(frame);
    if(unit->GetPos(frame).SqDistance2D(at)<=radius*radius) {
        if(!waiting) {
            TRY_UNIT(ai,unit,unit->CmdStop();unit->GetUnit()->Wait();)
            waiting=true;
        }
        return;
    }
    // Only retain an owned live move within its expiry, at the same goal.
    // No GUARD, PATROL or builder auto-work is issued by this task.
    if(!waiting && frame<sent+2*FRAMES_PER_SEC && goal.SqDistance2D(at)<SQUARE(64.f)
        && ai->GetUnitAPI()->GetCMDQueueSize(unit->GetId())>0) return;
    waiting=false;goal=at;sent=frame;
    TRY_UNIT(ai,unit,unit->CmdMoveTo(goal,0,frame+3*FRAMES_PER_SEC);)
}
}
