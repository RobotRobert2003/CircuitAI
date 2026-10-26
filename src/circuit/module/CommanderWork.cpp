#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/FactoryManager.h"
#include "task/builder/BuilderTask.h"
#include "task/builder/RepairTask.h"
#include "unit/CircuitUnit.h"
#include "unit/ally/AllyUnit.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "map/ThreatMap.h"
#include "terrain/TerrainManager.h"
#include "terrain/BattleAnalysis.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include <algorithm>
#include <functional>
#include <limits>

#include "Feature.h"
#include "FeatureDef.h"

namespace circuit {
using springai::AIFloat3;
using commander::Point;
using BT=IBuilderTask::BuildType;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }
static AIFloat3 F(Point p,float y=0) { return {p.x,y,p.z}; }

// D-299: the FRONT commander's work ladder. The script (CommanderFront::Work)
// owns the order and the definitions; each kind here is one bounded,
// commander-local selection. Called only from the builder's task offer for an
// idle commander (not per frame). Costs per offer, K = units/features inside
// the work radius (the commander's LOS, ~450 elmos): repair O(K log K) plus at
// most four reach/clearance checks; reclaim O(K) feature wrappers; radar O(N)
// over the ally snapshot at most once a second per commander (cached); line
// O(K + T) over the defence tasks. No new recurring cadence, no orders here:
// the returned task is assigned by the builder manager like any other offer.

float CCommanderControl::WorkRadius(CCircuitUnit* unit) const {
    return options.workRadius>0 ? options.workRadius : std::max(200.f,unit->GetCircuitDef()->GetLosRadius());
}

bool CCommanderControl::LineWorking(CCircuitUnit* unit,const State& s,IUnitTask* current,int frame) const {
    if(!LadderActive() || current==nullptr) return false;
    // The builder offers the next task on its own update after a Handover.
    if(current->GetType()==IUnitTask::Type::IDLE) return frame<s.lineYield+2*FRAMES_PER_SEC;
    auto* build=dynamic_cast<IBuilderTask*>(current);
    if(build==nullptr || build->IsDead() || build->IsExternalControlled() || build->IsEnemyReclaim()
        || build->GetManager()!=ai->GetBuilderManager()) return false;
    const float slack=unit->GetCircuitDef()->GetBuildDistance()+32.f;
    // A site outside (offered earlier, moved by native placement, or a
    // perimeter that shrank when its porc died) is not line work: the
    // controller takes the commander back. INV-218 is checked by Fallback on
    // the commander's own position while it works.
    return s.fallbackBoundary.Contains(P(build->GetPosition()),slack);
}

IUnitTask* CCommanderControl::LadderWork(CCircuitUnit* unit,State& s,int kind,CCircuitDef* buildDef,float radius,int frame) {
    if(!options.work) return nullptr;
    const AIFloat3 pos=unit->GetPos(frame);
    const bool holding=FallbackActive(s,frame);
    const float work=radius>0?radius:WorkRadius(unit);
    switch(kind) {
        case WORK_LINE: return LineWork(unit,s,buildDef,frame);
        case WORK_REPAIR_DEFENCE: return RepairWork(unit,s,true,work,frame);
        case WORK_REPAIR_UNITS: return RepairWork(unit,s,false,work,frame);
        case WORK_REPAIR_COMBAT: return RepairWork(unit,s,false,std::max(1.f,unit->GetCircuitDef()->GetBuildDistance()-32.f),frame,true);
        case WORK_RECLAIM: return ReclaimWork(unit,s,work,frame);
        case WORK_RADAR: return RadarWork(unit,s,buildDef,frame);
        case WORK_MEX: {
            // Any open metal spot in the work radius (LOS), wherever the
            // commander stands. EnqueueMexWithin owns spot claims, allied
            // extractors, safe reach and idempotent re-offers. Under a held
            // fallback the disc shrinks to what fits inside the perimeter, so
            // no spot outside it is ever claimed.
            float area=work;
            if(holding) {
                const float inside=s.fallbackBoundary.radius+unit->GetCircuitDef()->GetBuildDistance()
                    -commander::Length(P(pos)-s.fallbackBoundary.anchor);
                area=std::min(area,inside);
                if(area<=0) return nullptr;
            }
            return ai->GetEconomyManager()->EnqueueMexWithin(unit,pos,area,0,true);
        }
        case WORK_TERRITORY_LINE: return holding?nullptr:TerritoryLineWork(unit,s,buildDef,frame);
        case WORK_MEX_DEFENCE: return holding?nullptr:MexDefenceWork(unit,s,buildDef,frame);
        case WORK_MEX_LANE: return holding?nullptr:LaneMexWork(unit,s,buildDef,frame);
        case WORK_TIMED: {
            // First timed_until seconds of the game: one of buildDef every
            // timed_interval after the commander first reaches the front.
            if(holding || buildDef==nullptr || !unit->GetCircuitDef()->CanBuild(buildDef) || s.frontArrived<0
                || frame>=int(options.timedUntil*FRAMES_PER_SEC)) return nullptr;
            const auto anchor=FrontPosition(unit,s,frame);
            if(anchor.x<0 || pos.SqDistance2D(anchor)>options.frontRadius*options.frontRadius*.25f
                || ai->GetThreatMap()->GetThreatAt(unit,pos)>options.frontThreat) return nullptr;
            auto next=s.timedNext.try_emplace(buildDef->GetId(),s.frontArrived).first;
            if(frame<next->second || ai->GetEconomyManager()->GetMetalCur()<buildDef->GetCostM()*.5f) return nullptr;
            auto* task=ai->GetBuilderManager()->Enqueue(TaskB::Common(BT::DEFENCE,IBuilderTask::Priority::NORMAL,
                buildDef,anchor,128.f,true,30*FRAMES_PER_SEC));
            if(task) next->second=frame+int(options.timedInterval*FRAMES_PER_SEC);
            return task;
        }
        case WORK_FACTORY: {
            // A plant guard drifts with the plant's output, too far for the
            // fallback perimeter (INV-218, played): construction only there.
            if(holding) return nullptr;
            const auto anchor=FrontPosition(unit,s,frame);
            if(anchor.x<0 || pos.SqDistance2D(anchor)>options.frontRadius*options.frontRadius*.25f) return nullptr;
            return AssistWork(unit,s,anchor,std::clamp(work,64.f,options.frontRadius),true,frame);
        }
        case WORK_BASE: {
            // "Fell back to main base": a fallback or its line hold, or no
            // reachable safe front. Assist base construction, then factories.
            const AIFloat3 base=ai->GetSetupManager()->GetBasePos();
            const bool fellBack=holding || frame<s.lineUntil || FrontPosition(unit,s,frame).x<0;
            if(!fellBack || pos.SqDistance2D(base)>options.baseRadius*options.baseRadius) return nullptr;
            const float area=radius>0?std::min(radius,options.baseRadius):options.baseRadius;
            IUnitTask* task=AssistWork(unit,s,base,area,false,frame);
            return task||holding?task:AssistWork(unit,s,base,area,true,frame);
        }
        default: return nullptr;
    }
}

IUnitTask* CCommanderControl::RepairWork(CCircuitUnit* unit,const State& s,bool defence,float radius,int frame,bool stationary) {
    if(!unit->GetCircuitDef()->IsAbleToRepair()) return nullptr;
    auto* builder=ai->GetBuilderManager();
    const AIFloat3 pos=unit->GetPos(frame);
    const float reach=unit->GetCircuitDef()->GetBuildDistance();
    struct Candidate { CAllyUnit* ally; AIFloat3 at; float tech,distance; int id; };
    std::vector<Candidate> candidates;
    workIds=ai->GetCallback()->GetFriendlyUnitIdsIn(pos,radius,false);
    for(int id:workIds) {
        if(id==unit->GetId()) continue;
        CAllyUnit* ally=ai->GetFriendlyUnit(id);
        CCircuitDef* def=ally?ally->GetCircuitDef():nullptr;
        if(def==nullptr || (stationary && !def->IsAttacker()) || (def->IsAbleToFly() && !stationary) || (!stationary && (!def->IsMobile() && def->IsAttacker())!=defence)) continue;
        auto* u=ally->GetUnit();
        const float health=u->GetHealth(),maxHealth=u->GetMaxHealth();
        // Nanoframes are construction (assist), not repair.
        if(u->IsBeingBuilt() || health<=0 || health>=maxHealth*(stationary?1.f:options.repairHealth) || builder->IsReclaimUnit(ally)) continue;
        const AIFloat3 at=ally->GetPos(frame);
        if(stationary && pos.SqDistance(at)>radius*radius) continue;
        if(!InsideLine(s,at,frame,reach)) continue;
        candidates.push_back({ally,at,defence?0.f:DefinitionFor(def).tech,pos.distance2D(at),id});
    }
    // Static defences nearest first; other units T3, then T2, then T1.
    std::sort(candidates.begin(),candidates.end(),[](const Candidate& a,const Candidate& b) {
        if(a.tech!=b.tech) return a.tech>b.tech;
        if(a.distance!=b.distance) return a.distance<b.distance;
        return a.id<b.id;
    });
    ai->GetThreatMap()->SetThreatType(unit);
    const size_t tried=std::min<size_t>(4,candidates.size());
    for(size_t i=0;i<tried;++i) {
        const auto& c=candidates[i];
        if(options.workClearance>0 && !ai->GetCallback()->GetEnemyUnitIdsIn(c.at,options.workClearance,false).empty()) continue;
        if(!ai->GetTerrainManager()->CanReachAtSafe2(unit,c.at,reach)) continue;
        IBuilderTask* task=builder->EnqueueRepairFor(c.ally,FRAMES_PER_SEC*60,unit);
        if(stationary) if(auto* repair=dynamic_cast<CBRepairTask*>(task)) repair->InviteStationaryCommander(unit->GetId());
        if(task && task->CanAssignTo(unit)) {
            return task;
        }
    }
    return nullptr;
}

IUnitTask* CCommanderControl::ReclaimWork(CCircuitUnit* unit,const State& s,float radius,int frame) {
    auto* economy=ai->GetEconomyManager();
    const float store=economy->GetMetalStore();
    if(!unit->GetCircuitDef()->IsAbleToReclaim() || store<=0 || economy->GetMetalCur()>=store*options.reclaimStorage) return nullptr;
    auto* builder=ai->GetBuilderManager();
    const AIFloat3 pos=unit->GetPos(frame);
    const float reach=unit->GetCircuitDef()->GetBuildDistance();
    struct Candidate { AIFloat3 at; float metal,distance; int id; };
    std::vector<Candidate> candidates;
    auto features=ai->GetCallback()->GetFeaturesIn(pos,radius,false);
    for(springai::Feature* f:features) {
        springai::FeatureDef* def=f->GetDef();
        const bool reclaimable=def!=nullptr && def->IsReclaimable();
        const float metal=reclaimable?def->GetContainedResource(economy->GetMetalRes())*f->GetReclaimLeft():0.f;
        delete def;
        if(metal<=0 || metal<options.reclaimMetal) continue;
        const AIFloat3 at=f->GetPosition();
        if(!InsideLine(s,at,frame,reach) || builder->IsResurrect(at,8.f)) continue;
        candidates.push_back({at,metal,pos.distance2D(at),f->GetFeatureId()});
    }
    utils::free_clear(features);
    std::sort(candidates.begin(),candidates.end(),[](const Candidate& a,const Candidate& b) {
        return a.distance!=b.distance?a.distance<b.distance:a.id<b.id;
    });
    ai->GetThreatMap()->SetThreatType(unit);
    const size_t tried=std::min<size_t>(4,candidates.size());
    for(size_t i=0;i<tried;++i) {
        const auto& c=candidates[i];
        if(IBuilderTask* claim=builder->GetReclaimFeatureTask(c.at,8.f)) {
            if(!claim->IsDead() && claim->CanAssignTo(unit)) return claim;
            continue;
        }
        if(options.workClearance>0 && !ai->GetCallback()->GetEnemyUnitIdsIn(c.at,options.workClearance,false).empty()) continue;
        if(!ai->GetTerrainManager()->CanReachAtSafe2(unit,c.at,reach)) continue;
        return builder->Enqueue(TaskB::Reclaim(IBuilderTask::Priority::HIGH,c.at,c.metal,FRAMES_PER_SEC*60,8.f));
    }
    return nullptr;
}

IUnitTask* CCommanderControl::LineWork(CCircuitUnit* unit,State& s,CCircuitDef* buildDef,int frame) {
    if(buildDef==nullptr || !unit->GetCircuitDef()->CanBuild(buildDef) || s.lineAnchor.x<0
        || (!FallbackActive(s,frame) && frame>=s.lineUntil)) return nullptr;
    // The planned line can flip between a porc and a distant rear station
    // from one second to the next; build only at a line the commander holds.
    if(unit->GetPos(frame).SqDistance2D(s.lineAnchor)>4.f*options.lineRadius*options.lineRadius) return nullptr;
    auto* builder=ai->GetBuilderManager();
    // One line = every turret of buildDef within line_radius of the line's
    // porc (or rear station). Counting what stands there, rather than what
    // this commander ordered, is what stops repeat fallbacks from stacking.
    const float income=ai->GetEconomyManager()->GetAvgMetalIncome();
    int quota=options.lineIncome>0?int(income/options.lineIncome):int(options.lineMax);
    quota=std::min(std::max(quota,int(options.lineMin)),int(options.lineMax));
    int count=0;
    workIds=ai->GetCallback()->GetFriendlyUnitIdsIn(s.lineAnchor,options.lineRadius,false);
    for(int id:workIds) if(ai->GetCallback()->Unit_GetDefId(id)==buildDef->GetId()) ++count;
    IBuilderTask* open=nullptr;
    const float reach=unit->GetCircuitDef()->GetBuildDistance();
    for(IBuilderTask* task:builder->GetTasks(BT::DEFENCE)) {
        // A planned turret outside a held perimeter is not part of the line.
        if(task->IsDead() || task->GetBuildDef()!=buildDef
            || task->GetPosition().SqDistance2D(s.lineAnchor)>options.lineRadius*options.lineRadius
            || !InsideLine(s,task->GetPosition(),frame,reach)) continue;
        if(task->GetTarget()==nullptr) ++count; // not yet a nanoframe
        if(open==nullptr && task->CanAssignTo(unit)) open=task;
    }
    if(open) return open; // finish a planned line turret before another
    if(count>=quota) {
        if(!s.lineDone) ai->LOG("[CommanderWork] unit=%i line complete count=%i quota=%i income=%.1f",unit->GetId(),count,quota,income);
        s.lineDone=true; return nullptr;
    }
    s.lineDone=false;
    // Spread along the line (perpendicular to the threat), half a spacing
    // behind the anchor: 0, +1, -1, +2, -2, ... slots by the current count.
    Point toThreat=commander::Normal(P(s.lineThreat)-P(s.lineAnchor));
    if(commander::Length(toThreat)<.5f) toThreat=commander::Normal(P(s.lineAnchor)-P(ai->GetSetupManager()->GetBasePos()));
    const auto site=commander::LineBuildSite(P(s.lineAnchor),toThreat,options.lineSpacing,count,[&](Point p) {
        const AIFloat3 at=F(p);
        return OnMap(at) && InsideLine(s,at,frame,0.f);
    });
    if(!site) return nullptr;
    AIFloat3 at=F(*site);
    at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
    auto* task=builder->Enqueue(TaskB::Common(BT::DEFENCE,IBuilderTask::Priority::HIGH,buildDef,at,32.f,true,30*FRAMES_PER_SEC));
    if(task) ai->LOG("[CommanderWork] unit=%i line turret %i/%i x=%.0f z=%.0f income=%.1f",
        unit->GetId(),count+1,quota,at.x,at.z,income);
    return task;
}

bool CCommanderControl::CanStartRadar(CCircuitUnit* unit) {
    // Ordinary defence-queue jobs must obey the same script-selected FRONT
    // coverage policy as the ladder. Other roles/openings keep their policy.
    if(!options.work || !options.frontDuty || !options.frontReady || !Handles(unit)) return true;
    auto found=commanders.find(unit->GetId());
    return found==commanders.end() || !RadarCovered(unit,found->second,ai->GetLastFrame());
}

bool CCommanderControl::RadarCovered(CCircuitUnit* unit,State& s,int frame) {
    const AIFloat3 pos=unit->GetPos(frame);
    if(frame>=s.radarFrame+FRAMES_PER_SEC || pos.SqDistance2D(s.radarPos)>200.f*200.f) {
        // Coverage by any friendly radar except commanders (its own radar
        // does not count). O(N) over the ally snapshot, cached for a second
        // and 200 elmos; radius per definition from the cached Definition.
        bool covered=false;
        for(const auto& [id,ally]:ai->GetFriendlyUnits()) {
            CCircuitDef* def=ally->GetCircuitDef();
            if(def==nullptr || def->IsRoleComm()) continue;
            const float radar=DefinitionFor(def).radar*options.radarCoverage;
            // Ally snapshots recreate wrappers with an unset last position.
            // Only radar candidates need a live, frame-cached position read;
            // do not populate positions for the entire allied army (D-310).
            if(radar>0 && ally->GetPos(frame).SqDistance2D(pos)<radar*radar) { covered=true; break; }
        }
        s.radarCovered=covered; s.radarFrame=frame; s.radarPos=pos;
    }
    return s.radarCovered;
}

IUnitTask* CCommanderControl::RadarWork(CCircuitUnit* unit,State& s,CCircuitDef* buildDef,int frame) {
    if(buildDef==nullptr || !unit->GetCircuitDef()->CanBuild(buildDef)) return nullptr;
    const AIFloat3 pos=unit->GetPos(frame);
    const bool holding=FallbackActive(s,frame);
    if(!InsideLine(s,pos,frame,0.f)) return nullptr;
    const float range=DefinitionFor(buildDef).radar*options.radarCoverage;
    if(range<=0 || RadarCovered(unit,s,frame)) return nullptr;
    auto* builder=ai->GetBuilderManager();
    // A planned radar that will cover us suppresses a second one; join it only
    // when it lies inside a held perimeter (INV-218: never walk out to it).
    const float reach=unit->GetCircuitDef()->GetBuildDistance();
    for(IBuilderTask* task:builder->GetTasks(BT::RADAR))
        if(!task->IsDead() && task->GetBuildDef()==buildDef && task->GetPosition().SqDistance2D(pos)<=range*range)
            return task->CanAssignTo(unit) && InsideLine(s,task->GetPosition(),frame,reach)?task:nullptr;
    if((!holding && ai->GetThreatMap()->GetThreatAt(unit,pos)>options.frontThreat)
        || ai->GetEconomyManager()->GetMetalCur()<buildDef->GetCostM()*.5f) return nullptr;
    auto* task=builder->Enqueue(TaskB::Common(BT::RADAR,IBuilderTask::Priority::NORMAL,buildDef,pos,96.f,true,30*FRAMES_PER_SEC));
    if(task) {
        s.radarFrame=-10000; // the new frame covers us on the next check
        // INV-220 (D-304): no new commander radar where an existing friendly
        // radar at least as strong already covers. Independent of the
        // snapshot: one engine area query per radar enqueue (rare). Restored
        // after the 0bcf08e4 merge dropped it.
        auto* clb=ai->GetCallback();
        for(int id:clb->GetFriendlyUnitIdsIn(pos,range,false)) {
            const int defId=clb->Unit_GetDefId(id);
            CCircuitDef* def=defId>0?ai->GetCircuitDefSafe(defId):nullptr;
            if(def && !def->IsRoleComm() && !def->IsMobile() && DefinitionFor(def).radar*options.radarCoverage>=range) {
                ai->LOG("[INVARIANT] INV-220 commander radar inside existing coverage unit=%i radar=%i x=%.0f z=%.0f",
                    unit->GetId(),id,pos.x,pos.z);
                break;
            }
        }
    }
    return task;
}

IUnitTask* CCommanderControl::AssistWork(CCircuitUnit* unit,const State& s,const AIFloat3& center,float radius,bool factories,int frame) {
    if(factories && !unit->GetCircuitDef()->IsAbleToAssist()) return nullptr;
    const AIFloat3 pos=unit->GetPos(frame);
    const float reach=unit->GetCircuitDef()->GetBuildDistance();
    IUnitTask* best=nullptr; CCircuitUnit* plant=nullptr;
    float bestDistance=std::numeric_limits<float>::max();
    workIds=ai->GetCallback()->GetFriendlyUnitIdsIn(center,radius,false);
    for(int id:workIds) {
        CCircuitUnit* worker=ai->GetTeamUnit(id);
        if(!worker || worker==unit || !worker->IsFinished()) continue;
        CCircuitDef* def=worker->GetCircuitDef();
        AIFloat3 at;
        IBuilderTask* task=nullptr;
        if(!factories) {
            // Join a constructor's actual build (frame or planned building).
            if(!def->IsMobile() || !def->IsBuilder()) continue;
            task=dynamic_cast<IBuilderTask*>(worker->GetTask());
            if(!task || !task->GetBuildDef() || task->IsDead() || task->IsExternalControlled()
                || task->IsEnemyReclaim() || !task->CanAssignTo(unit)) continue;
            at=task->GetPosition();
        } else {
            // A plant producing a unit (recruit task), not a nano turret.
            if(def->IsMobile() || !def->IsBuilder() || def->IsAssist() || def->GetBuildOptions().empty()
                || !worker->GetTask() || worker->GetTask()->GetType()!=IUnitTask::Type::FACTORY) continue;
            at=worker->GetPos(frame);
        }
        if(!InsideLine(s,at,frame,reach)) continue;
        const float distance=pos.SqDistance2D(at);
        if(distance<bestDistance) { bestDistance=distance; best=task; plant=factories?worker:nullptr; }
    }
    if(plant) return ai->GetBuilderManager()->EnqueueB(TaskB::Guard(IBuilderTask::Priority::NORMAL,plant,false,FRAMES_PER_SEC*20));
    return best;
}

// D-357: the corridor window a FRONT commander sweeps for metal. A spot
// qualifies when it lies within the lane's half-width plus reach of the
// corridor (O(1) grid read) and its lane progress is between behind and
// ahead of the commander's own. Without capture, a spot with any enemy unit
// on it is skipped; with capture, an enemy extractor there is a target (the
// mex task reclaims it before building, MexTask.cpp) unless the threat map
// says the spot is hot. One bounded engine area query per candidate spot
// (spots inside the window, typically under twenty), per offer, not per frame.
static std::function<bool(const AIFloat3&)> LaneMexAccept(CCircuitAI* ai,CCircuitUnit* unit,const CBattleAnalysis* battle,
        float width,float lo,float hi,bool capture,float frontThreat,float enemyHome,bool losOnly) {
    return [=](const AIFloat3& p) {
        if(battle->GetFrontLaneDistance(p)>width) return false;
        if(losOnly && p.SqDistance2D(unit->GetPos(ai->GetLastFrame()))>SQUARE(unit->GetCircuitDef()->GetLosRadius())) return false;
        // The enemy's home spots (front_mex_enemy_home of an enemy start) are a
        // commander rush, not a lane sweep (hold arena, b02: taking and fortifying
        // the spot 630 elmos from the enemy start drew its commander into a fight).
        if(enemyHome>0 && battle->EnemyEndDistance(p)<enemyHome) return false;
        const float progress=battle->GetFrontLaneProgress(p);
        if(progress<lo || progress>hi) return false;
        const bool enemyOnSpot=!ai->GetCallback()->GetEnemyUnitIdsIn(p,64.f,false).empty();
        if(!enemyOnSpot) return true;
        return capture && ai->GetThreatMap()->GetThreatAt(unit,p)<=frontThreat;
    };
}

// The lane progress the sweep may reach ahead of the commander: its push
// anchor (one cached FrontPosition per second), or its own progress when the
// lane has no front for it (home latch, unreachable or exposed anchor).
float CCommanderControl::LaneMexAheadLimit(CCircuitUnit* unit,State& s,int frame,float own) {
    const AIFloat3 anchor=FrontPosition(unit,s,frame);
    return anchor.x<0?own:std::max(own,ai->GetBattle()->GetFrontLaneProgress(anchor));
}

IUnitTask* CCommanderControl::LaneMexWork(CCircuitUnit* unit,State& s,CCircuitDef* turretDef,int frame) {
    const auto* battle=ai->GetBattle();
    if(battle->GetFrontLaneLength()<=0.f) return nullptr;
    const AIFloat3 pos=unit->GetPos(frame);
    auto* builder=ai->GetBuilderManager();
    auto* clb=ai->GetCallback();
    // The turret that follows every front_mex_turret_every corridor mexes:
    // the script's line turret definition, at the last mex taken ("mex plus
    // LLT at the cluster"), once, unless one already stands or is planned there.
    if(options.frontMexDefence<=0 && s.laneMexTurret && turretDef && options.frontMexTurretEvery>0 && s.laneMexLast.x>=0
        && unit->GetCircuitDef()->CanBuild(turretDef)) {
        const float near2=4.f*options.lineSpacing*options.lineSpacing;
        bool standing=false;
        workIds=clb->GetFriendlyUnitIdsIn(s.laneMexLast,2.f*options.lineSpacing,false);
        for(int id:workIds) if(clb->Unit_GetDefId(id)==turretDef->GetId()) { standing=true; break; }
        for(IBuilderTask* task:builder->GetTasks(BT::DEFENCE)) {
            if(task->IsDead() || task->GetBuildDef()!=turretDef || task->GetPosition().SqDistance2D(s.laneMexLast)>near2) continue;
            s.laneMexTurret=false;
            return task->CanAssignTo(unit)?task:nullptr;
        }
        if(standing) s.laneMexTurret=false;
        else if(ai->GetEconomyManager()->GetMetalCur()>=turretDef->GetCostM()*.5f
            && ai->GetThreatMap()->GetThreatAt(unit,s.laneMexLast)<=options.frontThreat) {
            auto* task=builder->Enqueue(TaskB::Common(BT::DEFENCE,IBuilderTask::Priority::NORMAL,turretDef,s.laneMexLast,128.f,true,30*FRAMES_PER_SEC));
            if(task) {
                s.laneMexTurret=false;
                ai->LOG("[CommanderFront] unit=%i lane_turret x=%.0f z=%.0f after=%i",unit->GetId(),s.laneMexLast.x,s.laneMexLast.z,s.laneMexCount);
                return task;
            }
        }
    }
    const float reach=options.frontMexReach>0?options.frontMexReach:unit->GetCircuitDef()->GetBuildDistance();
    const float width=battle->GetFrontLaneWidth()+reach;
    const float own=battle->GetFrontLaneProgress(pos);
    const float radius=options.frontMexLos>0?unit->GetCircuitDef()->GetLosRadius():std::max(options.frontMexBehind,options.frontMexAhead)+width;
    // The sweep never leads the front: spots ahead are taken only up to the
    // push anchor (screen rule, front_distance, lane limit, enemy-group
    // stand-off, threat), so the commander does not creep mex by mex into an
    // enemy it would not walk toward (hold arena, b01: both commanders met).
    const auto accept=LaneMexAccept(ai,unit,battle,width,own-(options.frontMexLos>0?radius:options.frontMexBehind),
        std::min(own+(options.frontMexLos>0?radius:options.frontMexAhead),LaneMexAheadLimit(unit,s,frame,own)),
        options.frontMexCaptureEnemy>0,options.frontThreat,options.frontMexEnemyHome,options.frontMexLos>0);
    IBuilderTask* task=ai->GetEconomyManager()->EnqueueMexWithin(unit,pos,radius,0,true,{},accept);
    if(task) {
        const AIFloat3 at=task->GetPosition();
        if(at.SqDistance2D(s.laneMexLast)>64.f*64.f) {
            s.laneMexLast=at; ++s.laneMexCount;
            if(options.frontMexTurretEvery>0 && s.laneMexCount%int(options.frontMexTurretEvery)==0) s.laneMexTurret=true;
            ai->LOG("[CommanderFront] unit=%i lane_mex x=%.0f z=%.0f progress=%.0f own=%.0f count=%i",
                unit->GetId(),at.x,at.z,battle->GetFrontLaneProgress(at),own,s.laneMexCount);
        }
    }
    return task;
}

// The dry form of LaneMexWork's admission (the same window and the same
// economy admission, with no claim made), for INV-235 at the advance rung.
bool CCommanderControl::LaneMexAvailable(CCircuitUnit* unit,State& s,int frame) {
    const auto* battle=ai->GetBattle();
    if(FallbackActive(s,frame) || battle->GetFrontLaneLength()<=0.f) return false;
    const AIFloat3 pos=unit->GetPos(frame);
    const float reach=options.frontMexReach>0?options.frontMexReach:unit->GetCircuitDef()->GetBuildDistance();
    const float width=battle->GetFrontLaneWidth()+reach;
    const float own=battle->GetFrontLaneProgress(pos);
    const float radius=options.frontMexLos>0?unit->GetCircuitDef()->GetLosRadius():std::max(options.frontMexBehind,options.frontMexAhead)+width;
    const auto accept=LaneMexAccept(ai,unit,battle,width,own-(options.frontMexLos>0?radius:options.frontMexBehind),
        std::min(own+(options.frontMexLos>0?radius:options.frontMexAhead),LaneMexAheadLimit(unit,s,frame,own)),
        options.frontMexCaptureEnemy>0,options.frontThreat,options.frontMexEnemyHome,options.frontMexLos>0);
    return ai->GetEconomyManager()->CountOpenMexWithin(unit,pos,radius,true,accept)>0;
}
}
