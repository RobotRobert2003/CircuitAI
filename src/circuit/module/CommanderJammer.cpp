#include "module/CommanderControl.h"
#include "terrain/CommanderFortification.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"
#include "task/builder/CommanderTask.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"
#include "unit/ally/AllyUnit.h"
#include "spring/SpringCallback.h"
#include "spring/SpringUnit.h"
#include "spring/SpringMap.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include <limits>
#include "task/common/WaitTask.h"

namespace circuit {
using springai::AIFloat3;
using commander::Point;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }

void CCommanderControl::InitJammerRadii() {
    // UnitDef radii are immutable for this AI lifetime. Cache only metadata;
    // membership/activation is deliberately fresh on damage as well as ticks.
    // One bounded spatial query, O(local allies), no whole-army sensor census.
    if(maxJammerRadius<0) {
        maxJammerRadius=0;
        // CircuitDefs stores N entries, but engine IDs are 1..N.
        jammerRadii.resize(ai->GetCircuitDefs().size()+1,0.f);
        for(auto& def:ai->GetCircuitDefs()) if(def.GetDef()) {
            const float radius=def.GetDef()->GetJammerRadius();
            jammerRadii[def.GetId()]=radius;
            maxJammerRadius=std::max(maxJammerRadius,radius);
        }
    }
}

commander::JammerCoverage CCommanderControl::GroupJammerCoverage(CCircuitUnit* unit,CCircuitDef* def,
    const AIFloat3& center,float searchRadius,const IUnitTask* ignore) {
    if(!options.frontDuty || !options.frontReady || !def || def->GetId()!=groupJammer
        || (unit->GetId()!=groupUnit && !Handles(unit))) return commander::JammerCoverage{};
    InitJammerRadii();
    std::vector<commander::JammerCoverage::Disc> discs;
    // Include every disc intersecting any candidate's margin neighbourhood.
    // Fresh membership and sensor state; immutable radii alone are cached.
    // Own unstarted jobs and allied frames reserve space, never safety cover.
    const float radius=maxJammerRadius+searchRadius+options.groupJammerEdge;
    const auto ids=ai->GetCallback()->GetFriendlyUnitIdsIn(center,radius,false);
    const auto* ignoredBuild=dynamic_cast<const IBuilderTask*>(ignore);
    const auto* ignoredTarget=ignoredBuild?ignoredBuild->GetTarget():nullptr;
    for(int id:ids) {
        if(ignoredTarget && ignoredTarget->GetId()==id) continue;
        const int definition=ai->GetCallback()->Unit_GetDefId(id);
        if(definition<=0 || size_t(definition)>=jammerRadii.size() || jammerRadii[definition]<=0) continue;
        auto* ally=ai->GetFriendlyUnit(id);
        if(!ally || (!ally->GetUnit()->IsBeingBuilt() && !ai->GetUnitAPI()->IsActiveSensor(id))) continue;
        discs.push_back({P(ally->GetPos(ai->GetLastFrame())),jammerRadii[definition]});
    }
    for(auto* task:ai->GetBuilderManager()->GetTasks(IBuilderTask::BuildType::DEFENCE)) {
        auto* definition=task->GetBuildDef();
        if(task==ignore || task->IsDead() || !definition || task->GetTarget()) continue;
        const int id=definition->GetId();
        if(id<=0 || size_t(id)>=jammerRadii.size() || jammerRadii[id]<=0
            || task->GetPosition().SqDistance2D(center)>radius*radius) continue;
        discs.push_back({P(task->GetPosition()),jammerRadii[id]});
    }
    return commander::JammerCoverage(std::move(discs));
}

bool CCommanderControl::Jammed(CCircuitUnit* unit) {
    jamZones.clear();
    if(options.jamSafe<=0 || !Handles(unit) || EnergyRetreat(unit) || HealthRetreat(unit)) return false;
    InitJammerRadii();
    if(maxJammerRadius<=0) return false;
    const int frame=ai->GetLastFrame();
    const auto pos=unit->GetPos(frame);
    jammerIds=ai->GetCallback()->GetFriendlyUnitIdsIn(pos,maxJammerRadius,false);
    for(int id:jammerIds) {
        const int def=ai->GetCallback()->Unit_GetDefId(id);
        if(def<=0 || size_t(def)>=jammerRadii.size() || jammerRadii[def]<=0) continue;
        auto* ally=ai->GetFriendlyUnit(id);
        if(!ally || !ai->GetUnitAPI()->IsActiveSensor(id)) continue;
        const auto center=P(ally->GetPos(frame));
        if(commander::Length(P(pos)-center)<=jammerRadii[def]) jamZones.push_back({center,jammerRadii[def]});
    }
    return !jamZones.empty();
}

bool CCommanderControl::JamControl(CCircuitUnit* unit,State& s,int frame) {
    // Observe refreshed these zones immediately before this call. No borrowed
    // wrappers survive callbacks; loss, movement, paralysis and toggle-off are
    // evaluated again at the ordinary combat cadence and final shot admission.
    if(jamZones.empty()) return false;
    const auto pos=unit->GetPos(frame);
    auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask());
    const bool wasWithdrawing=s.fallback || s.mode==Mode::ESCAPE || s.mode==Mode::RECOVER
        || unit->GetTask()->GetType()==IUnitTask::Type::RETREAT;
    s.fallback=false;s.fallbackUntil=-1;s.unseenUntil=0;s.fallbackMoveUntil=-1;
    if(s.pending>=0) {
        if(unit->GetDGunReloadFrame()>frame || frame-s.pending>30) {
            s.pending=-1;s.leaseUntil=0;
            ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
        } else return true;
    }
    auto* def=unit->GetCircuitDef();
    const float range=unit->GetDGunRange()-12;
    const float speed=std::max(1.f,def->GetDGunDef()->GetDef()->GetProjectileSpeed()*30.f);
    const float width=std::min(24.f,std::max(4.f,def->GetDGunDef()->GetAoe()*.25f));
    commander::Line best;
    Point goal;
    float bestDistance=std::numeric_limits<float>::max();
    // Target scan reuses legal observations. Each candidate has at most one
    // projection per covering jammer; expensive route checks run only for a
    // candidate improving the current choice. Shot geometry remains shared.
    for(const auto& c:contacts) {
        if(c.friendly || c.blocker || c.reserved || !c.targetable
            || !(c.t3 || (c.combatTier==2 && c.cost>=options.jamHeavyCost))) continue;
        const auto lead=c.pos+c.velocity*(commander::Length(c.pos-P(pos))/speed);
        auto line=commander::ScoreLine(contacts,P(pos),lead-P(pos),range,speed,width,
            options.killReward,options.friendlyMargin,c.id);
        if(line.requiredHit && !line.blocked) {
            line.target=c.id; best=line;goal=P(pos);bestDistance=0;break;
        }
        for(const auto& zone:jamZones) {
            // Keep the destination inside coverage, including the footprint.
            auto candidate=commander::JamFiringPoint(zone.center,zone.radius,def->GetRadius()+16.f,lead);
            // Use the outer coverage edge when the comfortable inset would
            // discard an otherwise reachable shot. Revalidate live jamming at
            // firing time; the commander center must remain inside the disc.
            if(commander::Length(lead-candidate)>range+c.radius)
                candidate=commander::JamFiringPoint(zone.center,zone.radius,4.f,lead);
            if(commander::Length(lead-candidate)>range+c.radius) continue;
            const float distance=commander::Length(candidate-P(pos));
            if(distance>=bestDistance) continue;
            AIFloat3 at(candidate.x,0,candidate.z);
            if(!OnMap(at)) continue;
            at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
            if(at.y<0 || !Route(unit,pos,at)) continue;
            // Both endpoints lie in one convex coverage disc. Route validates
            // the straight terrain corridor; re-observation handles mobile jams.
            best.target=c.id;best.requiredHit=false;goal=candidate;bestDistance=distance;
        }
    }
    const bool heavyShot=best.target>=0;
    // Keep ordinary in-place D-gun opportunities while jammed too. Heavy
    // interception wins; ordinary groups retain the profile value threshold.
    if(!heavyShot && pos.y>=0 && unit->IsDGunReady(frame,
        ai->GetEconomyManager()->GetEnergyCur()-std::max(0.f,reserve))) {
        const float minimum=commander::MinimumValue(options.minValue,
            ai->GetMilitaryManager()->GetAggression(),options.aggression);
        for(int index:seeds) {
            const auto& c=contacts[index];
            if(std::abs(c.height-pos.y)>range*.5f) continue;
            const auto lead=c.pos+c.velocity*(commander::Length(c.pos-P(pos))/speed);
            auto line=commander::ScoreLine(contacts,P(pos),lead-P(pos),range,speed,width,
                options.killReward,options.friendlyMargin,c.id);
            if(line.requiredHit && !line.blocked && line.value>=minimum && line.value>best.value) {
                line.target=c.id;best=line;
            }
        }
    }
    if(best.target>=0 && pos.y>=0) {
        if(!task) {
            auto* previous=unit->GetTask();
            task=ai->GetBuilderManager()->EnqueueCommander(
                previous->GetType()==IUnitTask::Type::RETREAT?nullptr:previous);
            ai->GetBuilderManager()->AssignTask(unit,task);
            if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task);return true; }
            s.started=frame;++operation;
            unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
        }
        s.deployed=false;
        EndT3(unit,s,frame,"jam_intercept");
        s.budget=def->GetDGunDef()->GetCostE();
        if(best.requiredHit) {
            if(!unit->GetDGunAct() && Fire(unit,s,best,frame,false,heavyShot)) {
                ai->LOG("[CommanderJam] unit=%i target=%i action=fire frame=%i",unit->GetId(),best.target,frame);return true;
            }
            if(!s.route.empty()) { TRY_UNIT(ai,unit,unit->CmdStop();) s.route.clear(); }
        } else {
            AIFloat3 at(goal.x,0,goal.z);at.y=ai->GetMap()->GetElevationAt(at.x,at.z);
            Transition(unit,s,Mode::APPROACH,frame);Move(unit,s,at,frame);
        }
        return true;
    }
    s.budget=0;
    if(wasWithdrawing || (task && !s.deployed)) {
        // Do not restore a saved retreat or leave an old escape MOVE running.
        EndT3(unit,s,frame,"jam_hold");
        Transition(unit,s,Mode::SUPPORT,frame);s.route.clear();
        if(task) task->Handover(unit);
        else if(unit->GetTask()->GetType()==IUnitTask::Type::RETREAT) {
            TRY_UNIT(ai,unit,unit->CmdStop();)
            auto* hold=static_cast<IWaitTask*>(ai->GetBuilderManager()->Enqueue(TaskB::Wait(30)));
            hold->SetStationary(true);ai->GetBuilderManager()->AssignTask(unit,hold);
        }
        return true;
    }
    // Productive work and ordinary forward deployment continue; generic
    // withdrawal/intercept policy does not override the explicit jam-safe rule.
    Deploy(unit,s,frame);
    return true;
}
}
