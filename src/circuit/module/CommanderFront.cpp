#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"
#include "task/builder/CommanderTask.h"
#include "task/common/WaitTask.h"
#include "unit/CircuitUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "map/ThreatMap.h"
#include "terrain/TerrainManager.h"
#include "terrain/BattleAnalysis.h"
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
    auto* battle=ai->GetBattle();
    if(battle->GetFrontLaneLength()>0.f) {
        // D-356: the meta's "com forward until the first riot units appear,
        // then home". Once home, the lane has no front for this commander:
        // the ladder's base rungs (assist, plants) keep it busy at home.
        if(PushHome(unit,s,frame)) { s.pushBound=-1; s.pushGoalProgress=-1; return s.front={-1,0,-1}; }
        const float length=battle->GetFrontLaneLength();
        const float limit=std::max(0.f,length-options.frontStandoff);
        const float own=battle->GetFrontLaneProgress(unit->GetPos(frame));
        float advance=std::min(limit,std::min(options.frontDistance,length*.5f));
        // One existing bounded friendly query; only screens in our assigned
        // corridor advance this commander. Neighbouring lanes cannot pull it.
        // Legacy anchor: any mobile builder or attacker ahead pulls it forward.
        // Push anchor: combat units only are a screen (D-356); builders are not.
        int screens=0; float furthestScreen=-1,furthestAny=-1;
        const auto& ids=ai->GetCallback()->GetFriendlyUnitIdsIn(unit->GetPos(frame),options.scan,false);
        for(int id:ids) {
            if(id==unit->GetId())continue;
            auto* def=ai->GetCircuitDefSafe(ai->GetCallback()->Unit_GetDefId(id));
            if(!def || !def->IsMobile() || def->IsAbleToFly() || def->IsRoleComm()
                || (!def->IsBuilder() && !def->IsAttacker()))continue;
            float raw[3]={NAN,NAN,NAN};ai->GetUnitAPI()->GetPosition(id,raw);
            const AIFloat3 p(raw[0],raw[1],raw[2]);
            if(!std::isfinite(p.x) || !std::isfinite(p.z) || battle->GetFrontLaneDistance(p)>battle->GetFrontLaneWidth())continue;
            const float progress=battle->GetFrontLaneProgress(p);
            furthestAny=std::max(furthestAny,progress);
            if(def->IsAttacker()) { ++screens; furthestScreen=std::max(furthestScreen,progress); }
        }
        if(options.frontPushAhead>0) {
            const auto push=commander::LanePushAnchor(own,furthestScreen,screens,int(options.frontPushScreen),
                options.frontPushAhead,options.frontDistance,limit);
            advance=push.progress;
            s.pushScreens=screens; s.pushScreenProgress=furthestScreen; s.pushBound=push.bound;
        } else if(furthestAny>=0) {
            advance=std::max(advance,std::min(limit,furthestAny-100.f));
            s.pushBound=-1;
        }
        // Unscreened pushes may bridge an unreachable coarse sector up to
        // front_distance; screened pushes retain the screen-derived bound.
        float reachableBound=options.frontPushAhead>0
            ?std::min(limit,options.frontPushScreen>0?std::min(options.frontDistance,s.pushBound):options.frontDistance)
            :advance;
        // Cached observed enemy groups, not hidden enemy positions. An edge
        // threat within this corridor arrests its own commander's advance.
        for(const auto& group:ai->GetEnemyManager()->GetEnemyGroups())
            if(battle->GetFrontLaneDistance(group.pos)<=battle->GetFrontLaneWidth()) {
                const float boundary=std::max(0.f,battle->GetFrontLaneProgress(group.pos)-options.frontStandoff);
                advance=std::min(advance,boundary);reachableBound=std::min(reachableBound,boundary);
            }
        // Enemy groups behind the commander may stop a push, but must not
        // turn ordinary deployment into a trip home. Combat owns withdrawals.
        if(options.frontPersistent>0) { advance=std::max(own,advance);reachableBound=std::max(own,reachableBound); }
        auto anchor=battle->GetFrontLanePoint(advance);
        anchor.y=ai->GetMap()->GetElevationAt(anchor.x,anchor.z);
        // A corridor point can fall in a coarse terrain sector this commander
        // cannot enter. Keeping an already-arrived old anchor then stalls every
        // future deployment. Probe three earlier and three later points inside
        // the SAME safety bound;
        // this is endpoint admission, not a path solve or permission to pass a
        // threat/screen boundary. At most six extra queries per second, only
        // on an unreachable endpoint (commander-support-cortex regression).
        bool reachable=OnMap(anchor) && ai->GetTerrainManager()->CanReachAt(unit,anchor,64);
        if(options.frontPersistent>0 && OnMap(anchor) && !reachable) {
            for(float back:{128.f,256.f,384.f}) {
                const float progress=advance-back;
                if(progress<=own+options.frontRadius*.5f) break;
                auto probe=battle->GetFrontLanePoint(progress);
                probe.y=ai->GetMap()->GetElevationAt(probe.x,probe.z);
                if(OnMap(probe) && ai->GetTerrainManager()->CanReachAt(unit,probe,64)
                    && ai->GetThreatMap()->GetThreatAt(unit,probe)<=options.frontThreat) {
                    advance=progress;anchor=probe;reachable=true;break;
                }
            }
            if(!reachable) for(float ahead:{128.f,256.f,384.f}) {
                const float progress=std::min(reachableBound,advance+ahead);
                if(progress<=advance+64.f) break;
                auto probe=battle->GetFrontLanePoint(progress);
                probe.y=ai->GetMap()->GetElevationAt(probe.x,probe.z);
                if(OnMap(probe) && ai->GetTerrainManager()->CanReachAt(unit,probe,64)
                    && ai->GetThreatMap()->GetThreatAt(unit,probe)<=options.frontThreat) {
                    advance=progress;anchor=probe;reachable=true;break;
                }
            }
        }
        if(!reachable
            || ai->GetThreatMap()->GetThreatAt(unit,anchor)>options.frontThreat) {
            // Legacy: keep the last safe front. Push (D-356): the last front
            // may lie beyond the bound the screens now give (they fell back
            // while the fresh anchor is exposed); it is then no longer a legal
            // goal (INV-234 fired 160 times in the b03 Supreme natural game),
            // so the commander holds where it stands until the anchor clears.
            // The unscreened push (front_push_screen 0) keeps the legacy rule:
            // its only bound is front_distance, and a commander that fell back
            // in combat walks to its last safe front again.
            if(options.frontPushAhead>0 && options.frontPushScreen>0 && s.front.x>=0
                && battle->GetFrontLaneProgress(s.front)>std::min(options.frontDistance,s.pushBound)) {
                s.route.clear();
                // Standing beyond the bound itself (the screens fell back past
                // the commander) leaves no legal front: local work and combat
                // own the commander until the anchor clears (b04 Glacial:
                // holding in place at 1178 against a bound of 962 fired INV-234).
                if(own>std::min(options.frontDistance,s.pushBound)) { s.pushGoalProgress=-1; return s.front={-1,0,-1}; }
                auto hold=battle->GetFrontLanePoint(std::min(own,limit));
                hold.y=ai->GetMap()->GetElevationAt(hold.x,hold.z);
                s.pushGoalProgress=std::min(own,limit);
                return s.front=hold;
            }
            return battle->GetFrontLaneDistance(s.front)<=battle->GetFrontLaneWidth()?s.front:AIFloat3(-1,0,-1);
        }
        // A moving forward anchor is not a changed short-step intent. Keep the
        // owned queue; only a newly retreating boundary invalidates its goal.
        if(anchor.SqDistance2D(s.front)>64.f*64.f && (options.frontPushAhead<=0
            || battle->GetFrontLaneProgress(s.goal)>advance))s.route.clear();
        s.pushGoalProgress=advance;
        s.front=anchor;return anchor;
    }
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
    if(kind==19) return GroupWork(unit);
    if(HealthRetreat(unit) || EnergyRetreat(unit)) return nullptr;
    if(kind==WORK_SOLAR) {
        if(!Handles(unit) || !options.frontDuty || options.frontSolarIncome<=0 || !unit->IsFinished()) return nullptr;
        auto found=commanders.find(unit->GetId());
        if(found==commanders.end()) return nullptr;
        auto& state=found->second;
        auto* current=unit->GetTask();
        if(!current || current->IsExternalControlled() || current->IsEnemyReclaim()
            || current->GetType()==IUnitTask::Type::PLAYER || current->GetType()==IUnitTask::Type::RETREAT) return nullptr;
        if((state.workKind==WORK_SOLAR || state.workKind==WORK_REPAIR_COMBAT)
            && current==state.workTask && !current->IsDead()) return current;
        auto* eco=ai->GetEconomyManager();
        if(eco->GetAvgEnergyIncome()>=options.frontSolarIncome || eco->GetEnergyStore()<=0
            || eco->GetEnergyCur()>=eco->GetEnergyStore()*options.frontSolarStorage) return nullptr;
        // Priority-two repairs retain precedence over emergency economy. Only
        // ask the existing bounded repair selector when a solar is eligible;
        // ordinary deployment does not gain another friendly-unit query.
        if(options.frontRepairCombat>0) {
            if(auto* repair=FrontWork(unit,WORK_REPAIR_COMBAT,nullptr,0)) return repair;
        }
        const int frame=ai->GetLastFrame();
        if(frame<state.frontSolarNext) return nullptr;
        auto* def=buildDef?buildDef:ai->GetCircuitDefSafe(int(options.frontSolarDef));
        if(!def || !unit->GetCircuitDef()->CanBuild(def)) return nullptr;
        const auto pos=unit->GetPos(frame);
        const float reach=unit->GetCircuitDef()->GetBuildDistance();
        const float radius=options.frontSolarRadius;
        auto* terrain=ai->GetTerrainManager();
        auto* builder=ai->GetBuilderManager();
        CTerrainManager::TerrainPredicate allowed=[&](const AIFloat3& at) {
            return at.SqDistance2D(pos)<=radius*radius && InsideLine(state,at,frame,reach)
                && ai->GetThreatMap()->GetThreatAt(unit,at)<=options.frontThreat
                && terrain->CanReachAtSafe2(unit,at,reach);
        };
        // Task-offer work only: reuse a local energy claim before a bounded
        // nearest-site search. Failed placement retries after three seconds;
        // no map/army scan, no independent timer, and no base-layout detour.
        IBuilderTask* task=nullptr;
        for(auto* queued:builder->GetTasks(BT::ENERGY)) {
            if(!queued->IsDead() && queued->GetBuildDef()==def && allowed(queued->GetPosition())
                && queued->CanAssignTo(unit)) { task=queued;break; }
        }
        if(!task) {
            const auto site=terrain->FindBuildSite(def,pos,std::min(radius,std::max(32.f,reach-32.f)),0,allowed);
            const auto at=OnMap(site)?site:terrain->FindBuildSite(def,pos,radius,0,allowed);
            if(OnMap(at)) task=builder->Enqueue(TaskB::Common(BT::ENERGY,IBuilderTask::Priority::HIGH,def,at,0.f,true,60*FRAMES_PER_SEC));
        }
        if(!task) { state.frontSolarNext=frame+3*FRAMES_PER_SEC;return nullptr; }
        state.workTask=task;state.workKind=WORK_SOLAR;
        ai->LOG("[CommanderWork] unit=%i work=22 solar=%s income=%.1f storage=%.3f",unit->GetId(),def->GetDef()->GetName(),
            eco->GetAvgEnergyIncome(),eco->GetEnergyCur()/eco->GetEnergyStore());
        return task;
    }
    if(kind==20) return GroupAssist(unit);
    if(GroupActive(unit) && (kind==WORK_MEX_DEFENCE || kind==WORK_TERRITORY_LINE
        || kind==WORK_LINE || (kind==WORK_TIMED && buildDef && buildDef->GetId()==int(options.frontLineDef))
        || kind==3 || kind==WORK_RADAR || kind==2)) return nullptr;
    if(GroupActive(unit) && kind==WORK_MEX_LANE) buildDef=nullptr;
    if(!Handles(unit) || !options.frontDuty || !options.frontReady || !unit->IsFinished()
        || (kind!=WORK_HOLD && options.healthRetreatFraction<=0
            && unit->GetHealthPercent()<options.recover && !Jammed(unit))) return nullptr;
    auto found=commanders.find(unit->GetId()); if(found==commanders.end()) return nullptr;
    auto& s=found->second; const int frame=ai->GetLastFrame();
    const auto record=[&](IUnitTask* task) {
        // Lane mexes already passed their own LOS/reach/territory window before
        // claiming a spot. Reapplying the narrower generic-work window here
        // strands the claim and can alternate idle holds with deployment.
        // D-356: an offer whose site lies beyond the corridor (lane half-width
        // plus front_lane_margin, or the build distance) is declined, never
        // aborted: assist/repair/base rungs hand back tasks the shared queue
        // created for other builders, which keep them.
        if(auto* build=dynamic_cast<IBuilderTask*>(task);build && !FallbackActive(s,frame)
            && kind!=WORK_MEX_DEFENCE && kind!=WORK_TERRITORY_LINE && kind!=WORK_REPAIR_COMBAT && kind!=WORK_MEX_LANE
            && ai->GetBattle()->GetFrontLaneLength()>0.f
            && ai->GetBattle()->GetFrontLaneDistance(build->GetPosition())>ai->GetBattle()->GetFrontLaneWidth()
                +(options.frontLaneMargin>0?options.frontLaneMargin:unit->GetCircuitDef()->GetBuildDistance())) {
            task=nullptr;
        }
        if(auto* build=dynamic_cast<IBuilderTask*>(task); build && options.frontPersistent>0
            && !FallbackActive(s,frame) && ai->GetBattle()->GetFrontLaneLength()>0.f
            && kind!=WORK_MEX_DEFENCE && kind!=WORK_TERRITORY_LINE && kind!=WORK_REPAIR_COMBAT && kind!=WORK_MEX_LANE
            && ai->GetBattle()->GetFrontLaneProgress(build->GetPosition())
                <ai->GetBattle()->GetFrontLaneProgress(unit->GetPos(frame))-options.frontWorkBehind)
            task=nullptr; // decline shared work; never abort another builder's task
        // Native placement may move a site (shake, blocked cells). While a
        // fallback holds, an offer that ends outside the perimeter is dropped
        // here, and aborted when no one else took it (INV-218 at the source).
        if(auto* build=dynamic_cast<IBuilderTask*>(task); build && FallbackActive(s,frame)
            && !s.fallbackBoundary.Contains({build->GetPosition().x,build->GetPosition().z},unit->GetCircuitDef()->GetBuildDistance()+32.f)) {
            if(build->GetAssignees().empty()) ai->GetBuilderManager()->AbortTask(build);
            task=nullptr;
        }
        if(task && (kind==WORK_MEX_DEFENCE || kind==WORK_TERRITORY_LINE)
            && task->GetType()==IUnitTask::Type::BUILDER && options.frontFortifyAdvance>0)
            s.fortifyNextProgress=ai->GetBattle()->GetFrontLaneProgress(unit->GetPos(frame))+options.frontFortifyAdvance;
        s.workTask=task; s.workKind=kind; s.workHeld=FallbackActive(s,frame); s.workBoundary=s.fallbackBoundary;
        if(task) ai->LOG("[CommanderWork] unit=%i work=%i task=%i",unit->GetId(),kind,
            task->GetType()==IUnitTask::Type::BUILDER?int(static_cast<IBuilderTask*>(task)->GetBuildType()):-1);
        return task;
    };
    // The script offers kind 14 before local work. One cached lane lookup,
    // no extra army scan. Fallback and unfinished nearby structures retain
    // ownership; repairs/guard/base queues cannot monopolise a FRONT builder.
    if(kind==WORK_ADVANCE) {
        if(options.frontPushAhead<=0 || FallbackActive(s,frame)
            || (frame<s.lineUntil && !s.lineDone)
            || (s.territoryPending && options.frontFortifyAdvance<=0)) return nullptr;
        const auto anchor=FrontPosition(unit,s,frame),pos=unit->GetPos(frame);
        if(anchor.x<0 || pos.SqDistance2D(anchor)<=options.frontRadius*options.frontRadius*.25f) return nullptr;
        auto* build=dynamic_cast<IBuilderTask*>(unit->GetTask());
        if(build && !build->IsDead() && build->GetBuildDef() && CanResumeFrontTask(unit,build)
            && ((build->GetTarget() && !build->GetTarget()->IsFinished()) || build==s.workTask)
            && build->GetPosition().SqDistance2D(pos)<=std::pow(options.frontRadius+unit->GetCircuitDef()->GetBuildDistance(),2.f)) return build;
        if(dynamic_cast<CCommanderTask*>(unit->GetTask())) return unit->GetTask();
        // INV-235 (D-357): the commander advances by taking the next corridor
        // mex. The script ladder offers mex_lane before advance; if an admitted
        // corridor spot still exists here, the ladder order or the admission
        // disagrees, and the walk is refused so the next ask offers the spot.
        if(LaneMexAvailable(unit,s,frame)) {
            ai->LOG("[INVARIANT] INV-235 lane advance offered with an open corridor mex unit=%i x=%.0f z=%.0f",
                unit->GetId(),pos.x,pos.z);
            return nullptr;
        }
        s.frontProgressFrame=frame; s.frontProgressPos=pos;
        return ai->GetBuilderManager()->EnqueueCommander(nullptr);
    }
    // Script offers a bounded hold after productive front work. Engine PATROL
    // can acquire repair/reclaim work beyond its endpoint and out of the lane.
    // Cancel the old queue only when this task starts, never while offering it.
    if(kind==WORK_HOLD) {
        if(options.frontPushAhead<=0 || radius<=0 || (options.frontPersistent<=0 && FallbackActive(s,frame))) return nullptr;
        const auto anchor=FrontPosition(unit,s,frame);
        if(options.frontPersistent<=0 && (anchor.x<0 || unit->GetPos(frame).SqDistance2D(anchor)>
            options.frontRadius*options.frontRadius*.25f)) return nullptr;
        auto* hold=static_cast<IWaitTask*>(ai->GetBuilderManager()->Enqueue(
            TaskB::Wait(int(std::clamp(radius,1.f,30.f)*FRAMES_PER_SEC))));
        hold->SetStationary(true);
        return record(hold);
    }
    // Native Start can re-ask policy synchronously; keep a live ladder task.
    if(auto* current=unit->GetTask(); current && current==s.workTask && !current->IsDead()
        && CanResumeFrontTask(unit,current)) return current;
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

// D-356 "then home": the push ends after front_push_until_seconds of game
// time, or once the enemy's observed riot metal (the enemy manager's role
// census, no scan here) reaches front_push_home_riot. The latch never
// releases: the meta's rule is "com forward until the first riot units
// appear, then home" (53-expansion-and-territory.md). Zero disables a gate.
bool CCommanderControl::PushHome(CCircuitUnit* unit,State& s,int frame) {
    if(options.frontPersistent>0) { s.pushHome=false; return false; }
    if(s.pushHome || options.frontPushAhead<=0) return s.pushHome;
    const char* reason=nullptr;
    if(options.frontPushUntilSeconds>0 && frame>=int(options.frontPushUntilSeconds*FRAMES_PER_SEC)) reason="time";
    const float riot=options.frontPushHomeRiot>0?ai->GetEnemyManager()->GetEnemyCost(ROLE_TYPE(RIOT)):0.f;
    if(!reason && options.frontPushHomeRiot>0 && riot>=options.frontPushHomeRiot) reason="riot";
    if(!reason) return false;
    s.pushHome=true; s.route.clear();
    ai->LOG("[CommanderFront] unit=%i home reason=%s frame=%i riot_metal=%.0f",unit->GetId(),reason,frame,riot);
    return true;
}
}
