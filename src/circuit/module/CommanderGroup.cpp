#include "task/builder/CommanderGroupFollowTask.h"
#include "task/builder/CommanderTask.h"
#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "terrain/BattleAnalysis.h"
#include "terrain/TerrainManager.h"
#include "map/ThreatMap.h"
#include "unit/CircuitUnit.h"
#include "unit/ally/AllyUnit.h"
#include "spring/SpringCallback.h"
#include "spring/SpringUnit.h"
#include "task/common/WaitTask.h"
#include "task/common/RepairTask.h"
#include "task/builder/RepairTask.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include <algorithm>
#include <array>

namespace circuit {
using springai::AIFloat3;
using BT=IBuilderTask::BuildType;

CCircuitUnit* CCommanderControl::GroupCommander() const {
    if(!options.frontDuty || !options.frontReady) return nullptr;
    for(const auto& entry:commanders) {
        auto* unit=ai->GetTeamUnit(entry.first);
        if(unit && Handles(unit) && unit->IsFinished()) return unit;
    }
    return nullptr;
}

bool CCommanderControl::GroupActive(CCircuitUnit* commander) {
    auto* worker=ai->GetTeamUnit(groupUnit);
    if(!worker || !worker->IsFinished() || !commander || commander!=GroupCommander()) return false;
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    if(worker->GetPos(ai->GetLastFrame()).SqDistance2D(commander->GetPos(ai->GetLastFrame()))<=sight*sight)
        groupArrived=true;
    return groupArrived;
}

// Existing one-second group cadence; only borrowed current-task/target state.
// New construction, unfinished-frame repair and commander assistance share the
// same live-income gate. A full metal bank cannot substitute for income.
bool CCommanderControl::GroupTaskFunded(IUnitTask* task) const {
    if(ai->GetEconomyManager()->GetAvgMetalIncome()>=options.groupJammerIncome) return true;
    auto* build=dynamic_cast<IBuilderTask*>(task);
    auto* def=build?build->GetBuildDef():nullptr;
    if(!def) if(auto* repair=dynamic_cast<IRepairTask*>(task)) {
        auto* target=ai->GetTeamUnit(repair->GetTargetId());
        if(target) def=target->GetCircuitDef();
    }
    return !def || def->GetId()!=groupJammer;
}

bool CCommanderControl::CanResumeFrontTask(CCircuitUnit* unit,IUnitTask* task) const {
    if(!GroupTaskFunded(task)) return false;
    if(!options.frontDuty || !options.frontReady || options.frontPersistent<=0) return true;
    if(HealthRetreat(unit) || EnergyRetreat(unit)) return false;
    if(auto* repair=dynamic_cast<CBRepairTask*>(task); repair && repair->IsStationaryCommander(unit)) {
        auto* target=ai->GetFriendlyUnit(repair->GetTargetId());
        return target && target->GetPos(ai->GetLastFrame()).SqDistance(unit->GetPos(ai->GetLastFrame()))
            <=SQUARE(unit->GetCircuitDef()->GetBuildDistance());
    }
    auto* build=dynamic_cast<IBuilderTask*>(task);
    if(!build) return false; // never restore a roaming guard/patrol/base queue
    auto at=build->GetPosition();
    auto* definition=build->GetBuildDef();
    if(!definition) {
        // Only the selected worker's unfinished support frame may invite the
        // commander into a repair task. Generic base repairs stay excluded.
        auto* worker=ai->GetTeamUnit(groupUnit);
        auto* repair=dynamic_cast<IRepairTask*>(build);
        auto* target=repair?ai->GetTeamUnit(repair->GetTargetId()):nullptr;
        if(!worker || worker->GetTask()!=task || !target || target->IsFinished()) return false;
        definition=target->GetCircuitDef();at=target->GetPos(ai->GetLastFrame());
        const int id=definition->GetId();
        if(id!=groupNano && id!=groupDef && id!=groupRadar && id!=groupJammer && id!=groupAA) return false;
        if(id!=groupNano && !GroupPowered(at)) return false;
    }
    if(groupArrived && ai->GetTeamUnit(groupUnit)
        && definition->GetId()==int(options.frontLineDef)) return false;
    const auto pos=unit->GetPos(ai->GetLastFrame());
    const auto* battle=ai->GetBattle();
    const float sight=unit->GetCircuitDef()->GetLosRadius();
    if(at.SqDistance2D(pos)>sight*sight) return false;
    // Emergency energy is intentionally local to the commander, including
    // before a corridor exists; it must not need a lane/base-layout detour.
    if(definition->GetId()==int(options.frontSolarDef))
        return at.SqDistance2D(pos)<=SQUARE(options.frontSolarRadius);
    if(!GroupSiteAllowed(unit,at)) return false;
    auto* worker=ai->GetTeamUnit(groupUnit);
    const int defId=definition->GetId();
    // A selected group's lateral defense or radar package is still local
    // work even behind the ordinary mex window. Sight bounds the assistance;
    // the group planner, not a trip back to base, owns the site's admission.
    if(worker && worker->GetTask()==task && (defId==groupNano || defId==groupDef
        || defId==groupRadar || defId==groupJammer || defId==groupAA)) return true;
    return battle->GetFrontLaneLength()>0
        && battle->GetFrontLaneDistance(at)<=battle->GetFrontLaneWidth()+unit->GetCircuitDef()->GetBuildDistance()
        && battle->GetFrontLaneProgress(at)>=battle->GetFrontLaneProgress(pos)-options.frontWorkBehind;
}

bool CCommanderControl::GroupSiteAllowed(CCircuitUnit* unit,const AIFloat3& site) const {
    if(!options.frontDuty || !options.frontReady || options.frontPersistent<=0
        || (unit->GetId()!=groupUnit && !Handles(unit))) return true;
    const auto* battle=ai->GetBattle();
    if(battle->GetFrontLaneLength()<=0) return false;
    const int corridor=int(options.frontCorridor),cls=int(options.frontCorridorClass);
    // Territory lines span the whole assigned corridor, not just the lane
    // centre strip. Fallback routes without a corridor retain their lane bound.
    if(corridor>=0 && cls>=0) return battle->CorridorAtPoint(cls,site)==corridor;
    return battle->GetFrontLaneDistance(site)<=battle->GetFrontLaneWidth()
        +(options.frontLaneMargin>0?options.frontLaneMargin:unit->GetCircuitDef()->GetBuildDistance());
}

bool CCommanderControl::GroupMayBuild(CCircuitUnit* unit,CCircuitDef* def,const AIFloat3& site) const {
    if(!GroupSiteAllowed(unit,site) || HealthRetreat(unit) || EnergyRetreat(unit)) return false;
    if(unit->GetId()!=groupUnit) return true;
    auto* commander=GroupCommander();
    if(!commander || !def) return false;
    return site.SqDistance2D(commander->GetPos(ai->GetLastFrame()))<=SQUARE(commander->GetCircuitDef()->GetLosRadius())
        && (def->GetId()==groupNano || GroupPowered(site));
}

bool CCommanderControl::GroupPowered(const AIFloat3& site) const {
    // One local query per offered site, not a full census per army unit.
    // Only finished OWN turrets count. Engine membership is read fresh.
    auto* nano=ai->GetCircuitDefSafe(groupNano);
    if(!nano) return false;
    for(int id:ai->GetCallback()->GetFriendlyUnitIdsIn(site,nano->GetBuildDistance(),false)) {
        auto* unit=ai->GetTeamUnit(id);
        if(!unit || !unit->IsFinished()) continue;
        auto* def=unit->GetCircuitDef();
        if(!def->IsMobile() && def->GetWorkerTime()>0 && !def->IsBuilder()
            && site.SqDistance2D(unit->GetPos(ai->GetLastFrame()))<=SQUARE(def->GetBuildDistance())) return true;
    }
    return false;
}

IUnitTask* CCommanderControl::GroupPower(CCircuitUnit* unit,const AIFloat3& site,bool& covered) {
    covered=GroupPowered(site);
    if(covered) return nullptr;
    auto* nano=ai->GetCircuitDefSafe(groupNano);
    return nano?GroupBuild(unit,nano,site,true):nullptr;
}

IUnitTask* CCommanderControl::GroupBuild(CCircuitUnit* unit,CCircuitDef* def,const AIFloat3& site,bool bootstrap) {
    if(!def || !unit->GetCircuitDef()->CanBuild(def)) return nullptr;
    if(def->GetId()==groupJammer && ai->GetEconomyManager()->GetAvgMetalIncome()<options.groupJammerIncome) return nullptr;
    auto* builder=ai->GetBuilderManager();
    const int frame=ai->GetLastFrame();
    const BT type=bootstrap?BT::NANO:def->GetId()==groupRadar?BT::RADAR:BT::DEFENCE;
    for(auto* task:builder->GetTasks(type)) {
        if(task->GetBuildDef()!=def || task->IsDead() || task->IsExternalControlled()
            || task->GetPosition().SqDistance2D(site)>SQUARE(160.f)
            || !GroupSiteAllowed(unit,task->GetPosition())) continue;
        if(!bootstrap && !GroupPowered(task->GetPosition())) {
            bool covered=false;return GroupPower(unit,task->GetPosition(),covered);
        }
        if(task->CanAssignTo(unit)) return task;
    }
    const auto nearbyIds=ai->GetCallback()->GetFriendlyUnitIdsIn(site,160.f,false);
    for(int id:nearbyIds) {
        auto* target=ai->GetTeamUnit(id);
        if(!target || target->GetCircuitDef()!=def || !GroupSiteAllowed(unit,target->GetPos(frame))) continue;
        if(target->IsFinished()) return nullptr;
        if(bootstrap || GroupPowered(target->GetPos(frame)))
            return builder->EnqueueRepairFor(target,60*FRAMES_PER_SEC,unit);
    }
    auto* commander=GroupCommander();
    if(!commander) return nullptr;
    const auto center=commander->GetPos(frame);
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    const auto coverage=GroupJammerCoverage(unit,def,site,160.f);
    CTerrainManager::TerrainPredicate admit=[&](const AIFloat3& p) {
        return GroupSiteAllowed(unit,p) && coverage.NearUnjammed({p.x,p.z},options.groupJammerEdge)
            && p.SqDistance2D(center)<=sight*sight
            && (!bootstrap || p.SqDistance2D(site)<=SQUARE(std::max(32.f,def->GetBuildDistance()-32.f)))
            && ai->GetThreatMap()->GetThreatAt(unit,p)<=options.frontThreat
            && ai->GetTerrainManager()->CanReachAtSafe2(unit,p,unit->GetCircuitDef()->GetBuildDistance());
    };
    const auto at=ai->GetTerrainManager()->FindBuildSite(def,site,160.f,0,admit);
    if(!OnMap(at)) return nullptr;
    if(!bootstrap) {
        bool covered=false;auto* power=GroupPower(unit,at,covered);
        if(!covered) return power;
    }
    ai->LOG("[CommanderGroup] unit=%i build=%s bootstrap=%i x=%.0f z=%.0f metal=%.2f",unit->GetId(),def->GetDef()->GetName(),int(bootstrap),at.x,at.z,ai->GetEconomyManager()->GetAvgMetalIncome());
    return builder->Enqueue(TaskB::Common(type,IBuilderTask::Priority::HIGH,def,at,0.f,true,60*FRAMES_PER_SEC));
}

IUnitTask* CCommanderControl::GroupAssist(CCircuitUnit* commander) {
    if(HealthRetreat(commander) || EnergyRetreat(commander) || !GroupActive(commander)) return nullptr;
    auto* worker=ai->GetTeamUnit(groupUnit);
    auto* task=dynamic_cast<IBuilderTask*>(worker->GetTask());
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    if(worker->GetPos(ai->GetLastFrame()).SqDistance2D(commander->GetPos(ai->GetLastFrame()))>sight*sight
        || !task || task->IsDead() || task->IsExternalControlled()
        || task->IsEnemyReclaim() || !CanResumeFrontTask(commander,task)) return nullptr;
    if(auto* repair=dynamic_cast<IRepairTask*>(task)) {
        auto* target=ai->GetTeamUnit(repair->GetTargetId());
        if(!target) return nullptr;
        // The repair registry retains its single task owner and explicitly
        // invites this commander; do not create a competing repair job.
        task=ai->GetBuilderManager()->EnqueueRepairFor(target,60*FRAMES_PER_SEC,commander);
    }
    if(!task || !task->CanAssignTo(commander)) return nullptr;
    if(commander->GetTask()!=task) ai->LOG("[CommanderGroup] commander=%i assist=%i",commander->GetId(),worker->GetId());
    auto& state=commanders.find(commander->GetId())->second;
    state.workTask=task;state.workKind=20;
    return task;
}

IUnitTask* CCommanderControl::GroupWork(CCircuitUnit* unit) {
    if(!unit || unit->GetId()!=groupUnit || !unit->IsFinished()) return nullptr;
    auto* commander=GroupCommander();
    if(!commander) return nullptr;
    auto* current=unit->GetTask();
    if(current && (current->IsExternalControlled() || current->IsEnemyReclaim()
        || current->GetType()==IUnitTask::Type::PLAYER || current->GetType()==IUnitTask::Type::RETREAT)) return nullptr;
    const int frame=ai->GetLastFrame();
    const auto center=commander->GetPos(frame);
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    const bool nearby=unit->GetPos(frame).SqDistance2D(center)<=sight*sight;
    if(nearby) groupArrived=true;
    auto* builder=ai->GetBuilderManager();
    if(nearby) {
        if(auto* build=dynamic_cast<IBuilderTask*>(current); build && !build->IsDead() && build->GetBuildDef() && GroupTaskFunded(build)
            && (build->GetBuildDef()->GetId()==groupNano || build->GetBuildDef()->GetId()==groupDef
                || build->GetBuildDef()->GetId()==groupRadar || build->GetBuildDef()->GetId()==groupJammer || build->GetBuildDef()->GetId()==groupAA)
            && build->GetPosition().SqDistance2D(center)<=sight*sight
            && GroupSiteAllowed(unit,build->GetPosition())
            && (build->GetBuildDef()->GetId()==groupNano || GroupPowered(build->GetPosition()))) return build;
        // Complete radar packages before another defense. Queries are bounded
        // by commander sight. Distant sites do not drag this group back home.
        // Copy this bounded result: nested power queries reuse the callback
        // ID buffer. Never iterate borrowed IDs across another spatial query.
        const auto radarIds=ai->GetCallback()->GetFriendlyUnitIdsIn(center,sight,false);
        for(int id:radarIds) {
            auto* radar=ai->GetTeamUnit(id);
            if(!radar || radar->GetCircuitDef()->GetId()!=groupRadar || !GroupSiteAllowed(unit,radar->GetPos(frame))) continue;
            bool covered=false;auto* power=GroupPower(unit,radar->GetPos(frame),covered);
            if(!covered) { if(power) return power; continue; }
            if(auto* task=GroupBuild(unit,ai->GetCircuitDefSafe(groupJammer),radar->GetPos(frame))) return task;
        }
        auto& state=commanders.find(commander->GetId())->second;
        auto* defence=ai->GetCircuitDefSafe(groupDef);
        const auto* battle=ai->GetBattle();
        const float progress=battle->GetFrontLaneProgress(center);
        const float end=std::max(0.f,std::min(options.frontDistance,
            battle->GetFrontLaneLength()-options.frontStandoff)-options.frontRadius*.5f-64.f);
        const bool canFortify=options.frontFortifyAdvance<=0
            || progress>=std::min(state.fortifyNextProgress,end);
        // One defense job per commander advance, sharing the script's existing
        // incremental lever. Bootstrap power does not spend that allowance;
        // radar packages finish locally before following resumes. The terminal
        // cap accounts for the commander's arrival radius, avoiding an
        // impossible last progress gate (support faction/advance regressions).
        const auto fortification=[&](IUnitTask* task) {
            auto* build=dynamic_cast<IBuilderTask*>(task);
            auto* def=build?build->GetBuildDef():nullptr;
            if(!def) if(auto* repair=dynamic_cast<IRepairTask*>(task)) {
                auto* target=ai->GetTeamUnit(repair->GetTargetId());
                if(target) def=target->GetCircuitDef();
            }
            if(def && def==defence && options.frontFortifyAdvance>0)
                state.fortifyNextProgress=progress+options.frontFortifyAdvance;
            return task;
        };
        // Script/JSON owns new-job ordering. Three stack entries, no heap or
        // army scan; equal priorities retain mex, radar, line order. Zero
        // disables a new-job stage, never the coverage/completion prerequisites.
        std::array<std::pair<float,int>,3> order={{{options.groupMexPriority,0},
            {options.groupRadarPriority,1},{options.groupLinePriority,2}}};
        std::sort(order.begin(),order.end(),[](const auto& a,const auto& b) {
            return a.first!=b.first?a.first>b.first:a.second<b.second;
        });
        for(const auto& entry:order) {
            if(entry.first<=0) continue;
            if(entry.second==0) {
                if(auto* task=MexDefenceWork(unit,state,defence,frame)) return fortification(task);
            } else if(entry.second==1) {
                bool radarNearby=false;
                for(int id:ai->GetCallback()->GetFriendlyUnitIdsIn(center,options.radarSpacing,false)) {
                    auto* radar=ai->GetTeamUnit(id);
                    if(radar && radar->GetCircuitDef()->GetId()==groupRadar) { radarNearby=true;break; }
                }
                if(!radarNearby) if(auto* task=GroupBuild(unit,ai->GetCircuitDefSafe(groupRadar),center)) return task;
            } else if(canFortify) {
                if(auto* task=TerritoryLineWork(unit,state,defence,frame)) return fortification(task);
            }
        }
    }
    if(auto* follow=dynamic_cast<CCommanderGroupFollowTask*>(current); follow && !follow->IsDead()
        && follow->Target()==commander->GetId()) return follow;
    return builder->EnqueueCommanderGroupFollow(commander,sight*.5f);
}

void CCommanderControl::UpdateCommanderGroup() {
    const int frame=ai->GetLastFrame();
    if(frame<groupNext) return;
    groupNext=frame+FRAMES_PER_SEC;
    auto* unit=ai->GetTeamUnit(groupUnit);
    if(!unit || !unit->IsFinished()) return;
    // Release only these assignees; unfinished frames and other task owners
    // survive an income dip. Protected/player tasks are never cancelled.
    auto* commander=GroupCommander();
    for(auto* worker : {unit,commander}) {
        if(!worker) continue;
        auto* task=worker->GetTask();
        if(task && !task->IsExternalControlled() && !GroupTaskFunded(task)) {
            ai->LOG("[CommanderGroup] pause jammer unit=%i metal=%.2f",worker->GetId(),ai->GetEconomyManager()->GetAvgMetalIncome());
            auto* wait=ai->GetBuilderManager()->Enqueue(TaskB::Wait(FRAMES_PER_SEC));
            static_cast<IWaitTask*>(wait)->SetStationary(true);
            ai->GetBuilderManager()->AssignTask(worker,wait);
        }
    }
    if(auto* task=GroupWork(unit); task && task!=unit->GetTask()) ai->GetBuilderManager()->AssignTask(unit,task);
    // Join newly offered local work before deployment carries the commander
    // outside sight. Reuse this one-second group tick; productive work and
    // combat retain ownership. The AA/package regression covers this handoff.
    if(commander) {
        auto* moving=dynamic_cast<CCommanderTask*>(commander->GetTask());
        const auto state=commanders.find(commander->GetId());
        if(moving && state!=commanders.end() && state->second.deployed
            && state->second.mode==Mode::SUPPORT) {
            if(auto* assist=GroupAssist(commander)) ai->GetBuilderManager()->AssignTask(commander,assist);
        }
    }
}
}
