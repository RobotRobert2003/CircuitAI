#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"
#include "task/builder/CommanderTask.h"
#include "unit/CircuitUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "map/ThreatMap.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"

namespace circuit {
using springai::AIFloat3;
using BT=IBuilderTask::BuildType;

AIFloat3 CCommanderControl::FrontPosition(CCircuitUnit* unit,State& s,int frame) {
    // At most one bounded friendly query per commander/second, reused by the
    // role's task offers. No full friendly army census or per-frame path solve.
    // Positions expire after one second; combat still observes every 3 frames.
    if(frame<s.frontFrame+30) return s.front;
    s.frontFrame=frame;
    const auto home=ai->GetSetupManager()->GetStartPos();
    auto enemy=ai->GetEnemyManager()->GetNearestGroupPos(unit->GetPos(frame),options.minValue);
    if(enemy.x<0) enemy=ai->GetEnemyManager()->GetEnemyPos();
    if(enemy.x<0 || home.SqDistance2D(enemy)<1) return s.front={-1,0,-1};
    const auto delta=enemy-home;
    const float distance=delta.Length2D();
    const auto direction=delta/distance;
    // Secure the middle ground before contacts; a moving friendly screen or
    // constructor can pull this anchor forward, bounded by contact stand-off.
    const float limit=std::min(options.leash,std::max(0.f,distance-options.frontStandoff));
    float advance=std::min(limit,std::min(options.frontDistance,distance*.5f));
    AIFloat3 anchor=home+direction*advance;
    const auto& ids=ai->GetCallback()->GetFriendlyUnitIdsIn(anchor,options.scan,false);
    for(int id:ids) {
        if(id==unit->GetId()) continue;
        auto* def=ai->GetCircuitDefSafe(ai->GetCallback()->Unit_GetDefId(id));
        if(!def || !def->IsMobile() || def->IsAbleToFly() || def->IsRoleComm()
            || (!def->IsBuilder() && !def->IsAttacker())) continue;
        float raw[3]={NAN,NAN,NAN}; ai->GetUnitAPI()->GetPosition(id,raw);
        const AIFloat3 p(raw[0],raw[1],raw[2]);
        const float projection=(p.x-home.x)*direction.x+(p.z-home.z)*direction.z-100.f;
        if(projection>advance && projection<=limit) { advance=projection; anchor=p-direction*100.f; }
    }
    anchor.y=ai->GetMap()->GetElevationAt(anchor.x,anchor.z);
    if(!OnMap(anchor) || !ai->GetTerrainManager()->CanReachAt(unit,anchor,64)
        || ai->GetThreatMap()->GetThreatAt(unit,anchor)>options.frontThreat) {
        // Keep the last safe front; local combat can withdraw from it. Never
        // treat an unreachable/exposed destination as permission to idle home.
        return s.front;
    }
    if(anchor.SqDistance2D(s.front)>64.f*64.f) s.route.clear();
    s.front=anchor; return anchor;
}

IUnitTask* CCommanderControl::FrontWork(CCircuitUnit* unit,int kind,CCircuitDef* buildDef,float radius) {
    if(!Handles(unit) || !options.frontDuty || !options.frontReady || !unit->IsFinished()
        || unit->GetHealthPercent()<options.recover) return nullptr;
    auto found=commanders.find(unit->GetId()); if(found==commanders.end()) return nullptr;
    auto& s=found->second; const int frame=ai->GetLastFrame();
    const auto record=[&](IUnitTask* task) {
        s.workTask=task; s.workHeld=FallbackActive(s,frame); s.workBoundary=s.fallbackBoundary;
        if(task) ai->LOG("[CommanderWork] unit=%i work=%i task=%i",unit->GetId(),kind,
            task->GetType()==IUnitTask::Type::BUILDER?int(static_cast<IBuilderTask*>(task)->GetBuildType()):-1);
        return task;
    };
    // Native Start can re-ask policy synchronously; keep a live ladder task.
    if(auto* current=unit->GetTask(); current && current==s.workTask && !current->IsDead()) return current;
    // D-299 ladder kinds: commander-local, filtered to the perimeter while a
    // fallback holds. The script orders them (CommanderFront::Work).
    if(kind>=WORK_LINE) return record(LadderWork(unit,s,kind,buildDef,radius,frame));
    // D-293: no front work beyond the porc line while a fallback holds; D-299
    // assists construction inside it.
    if(FallbackActive(s,frame))
        return kind==0?record(AssistWork(unit,s,unit->GetPos(frame),WorkRadius(unit),false,frame)):nullptr;
    const auto anchor=FrontPosition(unit,s,frame),pos=unit->GetPos(frame);
    if(anchor.x<0) return nullptr;
    auto* builder=ai->GetBuilderManager();
    auto* current=dynamic_cast<IBuilderTask*>(unit->GetTask());
    if(current && !current->IsDead() && current->GetBuildDef() && current->GetManager()==builder
        && !current->IsExternalControlled() && !current->IsEnemyReclaim()
        && current->GetPosition().SqDistance2D(anchor)<=options.frontRadius*options.frontRadius) {
        // Native Start synchronously re-asks role policy before the frame exists.
        // Keep the travelling front claim, not just an already-built target.
        // Otherwise mex/radar offers can swap recursively in the same frame.
        return current;
    }
    if(pos.SqDistance2D(anchor)>options.frontRadius*options.frontRadius*.25f) {
        // Not while the last fallback line still wants turrets (D-299).
        if(kind!=4 || (frame<s.lineUntil && !s.lineDone)) return nullptr;
        s.frontProgressFrame=frame; s.frontProgressPos=pos;
        return builder->EnqueueCommander(nullptr);
    }
    if(s.frontArrived<0) s.frontArrived=frame; // D-299 timed defence clock
    if(ai->GetThreatMap()->GetThreatAt(unit,pos)>options.frontThreat) return nullptr;
    radius=std::clamp(radius,64.f,options.frontRadius);
    IUnitTask* result=nullptr;
    if(kind==0) {
        // Join the constructor's actual build task, rather than permanently
        // guarding it back to base. Local query order breaks equal-distance ties.
        const auto& ids=ai->GetCallback()->GetFriendlyUnitIdsIn(anchor,radius,false);
        float best=radius*radius;
        for(int id:ids) {
            auto* worker=ai->GetTeamUnit(id);
            if(!worker || worker==unit || !worker->IsFinished()
                || !worker->GetCircuitDef()->IsMobile() || !worker->GetCircuitDef()->IsBuilder()) continue;
            auto* task=dynamic_cast<IBuilderTask*>(worker->GetTask());
            if(!task || !task->GetBuildDef() || task->IsDead() || task->IsExternalControlled()
                || task->IsEnemyReclaim() || !task->CanAssignTo(unit)) continue;
            const float square=task->GetPosition().SqDistance2D(anchor);
            if(square<best) { best=square; result=task; }
        }
    } else if(kind==1) {
        result=ai->GetEconomyManager()->EnqueueMexWithin(unit,anchor,radius,0,true);
    } else if((kind==2 || kind==3) && buildDef && unit->GetCircuitDef()->CanBuild(buildDef)) {
        const BT type=kind==2?BT::RADAR:BT::DEFENCE;
        const auto& ids=ai->GetCallback()->GetFriendlyUnitIdsIn(anchor,radius,false);
        for(int id:ids) if(ai->GetCallback()->Unit_GetDefId(id)==buildDef->GetId()) return nullptr;
        for(auto* task:builder->GetTasks(type)) {
            if(task->GetBuildDef()==buildDef && task->GetPosition().SqDistance2D(anchor)<radius*radius)
                return !task->IsDead() && task->CanAssignTo(unit)?task:nullptr;
        }
        // Policy chooses the definition, priority order and spacing; native
        // placement/claims and build chains remain the sole structure owners.
        if(ai->GetEconomyManager()->GetMetalCur()>=buildDef->GetCostM()*.5f)
            result=builder->Enqueue(TaskB::Common(type,IBuilderTask::Priority::NORMAL,buildDef,anchor,96.f,true,30*30));
    } else if(kind==4) {
        result=builder->Enqueue(TaskB::Patrol(IBuilderTask::Priority::NORMAL,anchor,10*30));
    }
    if(result) ai->LOG("[CommanderFront] unit=%i work=%i x=%.0f z=%.0f",unit->GetId(),kind,anchor.x,anchor.z);
    return result;
}
}
