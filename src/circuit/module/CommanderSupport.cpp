#include "task/builder/FrontFollowTask.h"
#include "task/builder/CommanderTask.h"
#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
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

CCircuitUnit* CCommanderControl::SupportCommander() const {
    if(!options.frontDuty || !options.frontReady) return nullptr;
    for(const auto& entry:commanders) {
        auto* unit=ai->GetTeamUnit(entry.first);
        if(unit && Handles(unit) && unit->IsFinished()) return unit;
    }
    return nullptr;
}

bool CCommanderControl::SupportActive(CCircuitUnit* commander) {
    auto* worker=ai->GetTeamUnit(supportUnit);
    if(!worker || !worker->IsFinished() || !commander || commander!=SupportCommander()) return false;
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    if(worker->GetPos(ai->GetLastFrame()).SqDistance2D(commander->GetPos(ai->GetLastFrame()))<=sight*sight)
        supportArrived=true;
    return supportArrived;
}

bool CCommanderControl::CanResumeFrontTask(CCircuitUnit* unit,IUnitTask* task) const {
    if(!options.frontDuty || !options.frontReady || options.frontPersistent<=0) return true;
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
        auto* worker=ai->GetTeamUnit(supportUnit);
        auto* repair=dynamic_cast<IRepairTask*>(build);
        auto* target=repair?ai->GetTeamUnit(repair->GetTargetId()):nullptr;
        if(!worker || worker->GetTask()!=task || !target || target->IsFinished()) return false;
        definition=target->GetCircuitDef();at=target->GetPos(ai->GetLastFrame());
        const int id=definition->GetId();
        if(id!=supportNano && id!=supportDef && id!=supportRadar && id!=supportJammer && id!=supportAA) return false;
        if(id!=supportNano && !SupportPowered(at)) return false;
    }
    if(supportArrived && ai->GetTeamUnit(supportUnit)
        && definition->GetId()==int(options.frontLineDef)) return false;
    const auto pos=unit->GetPos(ai->GetLastFrame());
    const auto* battle=ai->GetBattle();
    const float sight=unit->GetCircuitDef()->GetLosRadius();
    if(at.SqDistance2D(pos)>sight*sight) return false;
    auto* worker=ai->GetTeamUnit(supportUnit);
    const int defId=definition->GetId();
    // A selected group's lateral defense or radar package is still local
    // work even behind the ordinary mex window. Sight bounds the assistance;
    // the group planner, not a trip back to base, owns the site's admission.
    if(worker && worker->GetTask()==task && (defId==supportNano || defId==supportDef
        || defId==supportRadar || defId==supportJammer || defId==supportAA)) return true;
    return battle->GetFrontLaneLength()>0
        && battle->GetFrontLaneDistance(at)<=battle->GetFrontLaneWidth()+unit->GetCircuitDef()->GetBuildDistance()
        && battle->GetFrontLaneProgress(at)>=battle->GetFrontLaneProgress(pos)-options.frontWorkBehind;
}

bool CCommanderControl::SupportMayBuild(CCircuitUnit* unit,CCircuitDef* def,const AIFloat3& site) const {
    if(unit->GetId()!=supportUnit) return true;
    auto* commander=SupportCommander();
    if(!commander || !def) return false;
    return site.SqDistance2D(commander->GetPos(ai->GetLastFrame()))<=SQUARE(commander->GetCircuitDef()->GetLosRadius())
        && (def->GetId()==supportNano || SupportPowered(site));
}

bool CCommanderControl::SupportPowered(const AIFloat3& site) const {
    // One local query per offered site, not a full census per army unit.
    // Only finished OWN turrets count. Engine membership is read fresh.
    auto* nano=ai->GetCircuitDefSafe(supportNano);
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

IUnitTask* CCommanderControl::SupportPower(CCircuitUnit* unit,const AIFloat3& site,bool& covered) {
    covered=SupportPowered(site);
    if(covered) return nullptr;
    auto* nano=ai->GetCircuitDefSafe(supportNano);
    return nano?SupportBuild(unit,nano,site,true):nullptr;
}

IUnitTask* CCommanderControl::SupportBuild(CCircuitUnit* unit,CCircuitDef* def,const AIFloat3& site,bool bootstrap) {
    if(!def || !unit->GetCircuitDef()->CanBuild(def)) return nullptr;
    auto* builder=ai->GetBuilderManager();
    const int frame=ai->GetLastFrame();
    const BT type=bootstrap?BT::NANO:def->GetId()==supportRadar?BT::RADAR:BT::DEFENCE;
    for(auto* task:builder->GetTasks(type)) {
        if(task->GetBuildDef()!=def || task->IsDead() || task->IsExternalControlled()
            || task->GetPosition().SqDistance2D(site)>SQUARE(160.f)) continue;
        if(!bootstrap && !SupportPowered(task->GetPosition())) {
            bool covered=false;return SupportPower(unit,task->GetPosition(),covered);
        }
        if(task->CanAssignTo(unit)) return task;
    }
    const auto nearbyIds=ai->GetCallback()->GetFriendlyUnitIdsIn(site,160.f,false);
    for(int id:nearbyIds) {
        auto* target=ai->GetTeamUnit(id);
        if(!target || target->GetCircuitDef()!=def) continue;
        if(target->IsFinished()) return nullptr;
        if(bootstrap || SupportPowered(target->GetPos(frame)))
            return builder->EnqueueRepairFor(target,60*FRAMES_PER_SEC,unit);
    }
    auto* commander=SupportCommander();
    if(!commander) return nullptr;
    const auto center=commander->GetPos(frame);
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    CTerrainManager::TerrainPredicate admit=[&](const AIFloat3& p) {
        return p.SqDistance2D(center)<=sight*sight
            && (!bootstrap || p.SqDistance2D(site)<=SQUARE(std::max(32.f,def->GetBuildDistance()-32.f)))
            && ai->GetThreatMap()->GetThreatAt(unit,p)<=options.frontThreat
            && ai->GetTerrainManager()->CanReachAtSafe2(unit,p,unit->GetCircuitDef()->GetBuildDistance());
    };
    const auto at=ai->GetTerrainManager()->FindBuildSite(def,site,160.f,0,admit);
    if(!OnMap(at)) return nullptr;
    if(!bootstrap) {
        bool covered=false;auto* power=SupportPower(unit,at,covered);
        if(!covered) return power;
    }
    ai->LOG("[FrontSupport] unit=%i build=%s bootstrap=%i x=%.0f z=%.0f",unit->GetId(),def->GetDef()->GetName(),int(bootstrap),at.x,at.z);
    return builder->Enqueue(TaskB::Common(type,IBuilderTask::Priority::HIGH,def,at,0.f,true,60*FRAMES_PER_SEC));
}

IUnitTask* CCommanderControl::SupportAssist(CCircuitUnit* commander) {
    if(!SupportActive(commander)) return nullptr;
    auto* worker=ai->GetTeamUnit(supportUnit);
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
    if(commander->GetTask()!=task) ai->LOG("[FrontSupport] commander=%i assist=%i",commander->GetId(),worker->GetId());
    auto& state=commanders.find(commander->GetId())->second;
    state.workTask=task;state.workKind=20;
    return task;
}

IUnitTask* CCommanderControl::SupportWork(CCircuitUnit* unit) {
    if(!unit || unit->GetId()!=supportUnit || !unit->IsFinished()) return nullptr;
    auto* commander=SupportCommander();
    if(!commander) return nullptr;
    auto* current=unit->GetTask();
    if(current && (current->IsExternalControlled() || current->IsEnemyReclaim()
        || current->GetType()==IUnitTask::Type::PLAYER || current->GetType()==IUnitTask::Type::RETREAT)) return nullptr;
    const int frame=ai->GetLastFrame();
    const auto center=commander->GetPos(frame);
    const float sight=commander->GetCircuitDef()->GetLosRadius();
    const bool nearby=unit->GetPos(frame).SqDistance2D(center)<=sight*sight;
    if(nearby) supportArrived=true;
    auto* builder=ai->GetBuilderManager();
    if(nearby) {
        if(auto* build=dynamic_cast<IBuilderTask*>(current); build && !build->IsDead() && build->GetBuildDef()
            && (build->GetBuildDef()->GetId()==supportNano || build->GetBuildDef()->GetId()==supportDef
                || build->GetBuildDef()->GetId()==supportRadar || build->GetBuildDef()->GetId()==supportJammer || build->GetBuildDef()->GetId()==supportAA)
            && build->GetPosition().SqDistance2D(center)<=sight*sight
            && (build->GetBuildDef()->GetId()==supportNano || SupportPowered(build->GetPosition()))) return build;
        // Complete radar packages before another defense. Queries are bounded
        // by commander sight. Distant sites do not drag this group back home.
        // Copy this bounded result: nested power queries reuse the callback
        // ID buffer. Never iterate borrowed IDs across another spatial query.
        const auto radarIds=ai->GetCallback()->GetFriendlyUnitIdsIn(center,sight,false);
        for(int id:radarIds) {
            auto* radar=ai->GetTeamUnit(id);
            if(!radar || radar->GetCircuitDef()->GetId()!=supportRadar) continue;
            bool covered=false;auto* power=SupportPower(unit,radar->GetPos(frame),covered);
            if(!covered) { if(power) return power; continue; }
            if(auto* task=SupportBuild(unit,ai->GetCircuitDefSafe(supportJammer),radar->GetPos(frame))) return task;
        }
        auto& state=commanders.find(commander->GetId())->second;
        auto* defence=ai->GetCircuitDefSafe(supportDef);
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
        std::array<std::pair<float,int>,3> order={{{options.supportMexPriority,0},
            {options.supportRadarPriority,1},{options.supportLinePriority,2}}};
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
                    if(radar && radar->GetCircuitDef()->GetId()==supportRadar) { radarNearby=true;break; }
                }
                if(!radarNearby) if(auto* task=SupportBuild(unit,ai->GetCircuitDefSafe(supportRadar),center)) return task;
            } else if(canFortify) {
                if(auto* task=TerritoryLineWork(unit,state,defence,frame)) return fortification(task);
            }
        }
    }
    if(auto* follow=dynamic_cast<CFrontFollowTask*>(current); follow && !follow->IsDead()
        && follow->Target()==commander->GetId()) return follow;
    return builder->EnqueueFrontFollow(commander,sight*.5f);
}

void CCommanderControl::UpdateSupport() {
    const int frame=ai->GetLastFrame();
    if(frame<supportNext) return;
    supportNext=frame+FRAMES_PER_SEC;
    auto* unit=ai->GetTeamUnit(supportUnit);
    if(!unit || !unit->IsFinished()) return;
    if(auto* task=SupportWork(unit); task && task!=unit->GetTask()) ai->GetBuilderManager()->AssignTask(unit,task);
    // Join newly offered local work before deployment carries the commander
    // outside sight. Reuse this one-second group tick; productive work and
    // combat retain ownership. The AA/package regression covers this handoff.
    auto* commander=SupportCommander();
    if(commander) {
        auto* moving=dynamic_cast<CCommanderTask*>(commander->GetTask());
        const auto state=commanders.find(commander->GetId());
        if(moving && state!=commanders.end() && state->second.deployed
            && state->second.mode==Mode::SUPPORT) {
            if(auto* assist=SupportAssist(commander)) ai->GetBuilderManager()->AssignTask(commander,assist);
        }
    }
}
}
