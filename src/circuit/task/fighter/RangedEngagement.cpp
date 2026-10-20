#include "task/fighter/RangedEngagement.h"
#include "task/UnitTask.h"
#include "CircuitAI.h"
#include "module/MilitaryManager.h"
#include "module/EconomyManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathSingle.h"
#include "terrain/path/QueryLineMap.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "spring/CustomCommand.h"
#include "spring/SpringUnit.h"
#include "util/Utils.h"
#include "util/Performance.h"
#include "Weapon.h"
#include "Log.h"
#include "WeaponMount.h"
#include "AISCommands.h"
#include <cmath>
#include <limits>
#include <cstdlib>

namespace circuit {
using springai::AIFloat3;
static ranged::Point P(const AIFloat3& p) { return {p.x,p.z}; }
static const bool trace = std::getenv("CIRCUIT_RANGED_TRACE") != nullptr;

CRangedEngagement::CRangedEngagement(CCircuitAI* ai,IUnitTask* owner,CCircuitUnit* unit)
    : ai(ai),owner(owner),worldOwner(ai->GetMilitaryManager()->GetRangedWorld()),world(*worldOwner),
      caps(world.CapabilitiesFor(unit->GetCircuitDef())),id(unit->GetId())
{
    lastPos=unit->GetPos(ai->GetLastFrame()); destination=lastPos;
    lastShotFrame=lastProgressFrame=ai->GetLastFrame();
    world.Join(unit); world.Refresh();
    unit->TrySetMoveState(CCircuitDef::HOLD_POS);
    // Priority targets are explicit user targets in BAR and can fire on HOLD.
    // Automatic fire would bypass precision/splash selection while approaching
    // the firing band (the engine includes target radius in reach).
    unit->TrySetFireState(CCircuitDef::HOLD);
    ai->LOG("RANGED: assigned %s(%d) weapons=%u",unit->GetCircuitDef()->GetDef()->GetName(),id,unsigned(caps.weapons.size()));
    if(caps.weapons.empty()) ai->LOG("[INVARIANT] INV-147 ranged unit %d has no compatible loaded weapon",id);
    if(trace) for(const auto& w:caps.weapons) ai->LOG("RANGED: weapon unit=%d index=%d range=%.1f speed=%.3f gravity=%.3f category=%d forward=%d",id,w.index,w.range,w.speed,w.gravity,w.category,int(w.forward));
}
CRangedEngagement::~CRangedEngagement()
{
    lifetime.reset(); query.reset();
    // Stop/ForgetUnit can bypass normal reassignment. Registry entries and
    // shot reservations must not survive any of those ownership boundaries.
    if(!released) world.Leave(id);
}
void CRangedEngagement::Release(CCircuitUnit* unit,bool commands)
{
    if(released) return;
    lifetime.reset(); query.reset(); ++generation; world.Leave(id); released=true;
    if(!commands || !unit || unit->IsDead()) return;
    if(target>=0) {
        TRY_UNIT(ai,unit,
            float params[]={float(target)};
            SendCustomCommand(ai->GetSkirmishAIId(),id,CMD_UNIT_CANCEL_TARGET,params);
        )
    }
    unit->TrySetMoveState(unit->GetCircuitDef()->GetMoveState());
    unit->TrySetFireState(unit->GetCircuitDef()->GetFireState());
}
void CRangedEngagement::SelectTarget(CCircuitUnit* unit,int selected,int weapon,float damage)
{
    const int frame=ai->GetLastFrame();
    if(selected==target && weapon==weaponIndex) {
        // BAR owns the actual priority target. A lost command must be repaired;
        // an unchanged live intent must not be resent each decision tick.
        if(selected<0 || frame-targetFrame<30 || int(unit->GetUnit()->GetRulesParamFloat("unitTargetID",-1.f))==selected) return;
    }
    // Owner 2026-10-19: a live priority target is kept for target_min_seconds;
    // each swap costs CANCEL+SET. A lost target, a cancel (selected<0) or a
    // pick worth 1.5x the reserved damage still switches at once.
    const float hold=unit->GetCircuitDef()->GetRangedPolicy().targetMinSeconds;
    if(target>=0 && selected>=0 && selected!=target && hold>0.f && frame-targetFrame<int(hold*FRAMES_PER_SEC)
        && damage<reservedDamage*1.5f && ai->GetEnemyManager()->GetEnemyUnit(target)!=nullptr
        && int(unit->GetUnit()->GetRulesParamFloat("unitTargetID",-1.f))==target) return;
    const int avoid=unit->GetCircuitDef()->GetRangedPolicy().avoidCategory;
    if(selected>=0 && avoid!=0) {
        // INV-207: every candidate loop filters identified avoided categories
        // before this call; a blind shot at an unidentified slow dot is legal
        // and never flagged. One enemy lookup per changed intent.
        auto* enemy=ai->GetEnemyManager()->GetEnemyUnit(selected);
        if(enemy && enemy->GetCircuitDef() && (enemy->GetCircuitDef()->GetCategory()&avoid)) {
            ai->LOG("[INVARIANT] INV-207 ranged unit %d selected identified avoided-category target %d (%s); refused",
                id,selected,enemy->GetCircuitDef()->GetDef()->GetName());
            selected=-1; weapon=-1; damage=0.f;
            if(target<0) return;
        }
    }
    if(selected!=target || weapon!=weaponIndex) world.ReleaseShot(id);
    TRY_UNIT(ai,unit,
        if(target>=0 && target!=selected) {
            float params[]={float(target)};
            SendCustomCommand(ai->GetSkirmishAIId(),id,CMD_UNIT_CANCEL_TARGET,params);
        }
        if(selected>=0) {
            float params[]={float(selected)};
            SendCustomCommand(ai->GetSkirmishAIId(),id,CMD_UNIT_SET_TARGET,params);
        }
    )
    if(weapon!=weaponIndex) {
        liveWeapon.reset(weapon>=0 ? unit->GetUnit()->GetWeapon(caps.weapons[weapon].mount.get()) : nullptr);
        lastReload=liveWeapon ? liveWeapon->GetReloadFrame() : -1;
    }
    target=selected; weaponIndex=weapon; targetFrame=frame; reservedDamage=damage;
    if(selected>=0) world.ReserveShot(id,selected,damage,frame+90);
}
void CRangedEngagement::Hold(CCircuitUnit* unit,bool unsafe)
{
    // Range eligibility alone cannot cancel a facing step. Safety owns an
    // immediate override; actual fire clears the commitment in Update.
    if(!unsafe && ai->GetLastFrame()<orientUntil) {
        ai->LOG("[INVARIANT] INV-164 ranged firing hold interrupted facing recovery unit=%d",id);
        return;
    }
    orientUntil=0;
    query.reset(); ++generation;
    if(moving && !issuing) {
        moving=false; path.clear(); issuing=true;
        TRY_UNIT(ai,unit,unit->CmdStop();)
        // STOP cancels BAR's priority target. Repair it in this same decision,
        // rather than waiting for an unrelated idle or retarget event.
        targetFrame=0;
        issuing=false;
    }
}
bool CRangedEngagement::SafeMove(CCircuitUnit* unit,const AIFloat3& from,const AIFloat3& to,float margin,bool escape)
{
    const auto& p=unit->GetCircuitDef()->GetRangedPolicy();
    return p.coordinated && p.engagementSeconds>0.f ? world.CohortSafe(unit,from,to,margin,escape)
        :world.Safe(from,to,margin,escape,p.pressStatic);
}
bool CRangedEngagement::LegalPath(CCircuitUnit* unit,const std::vector<AIFloat3>& route,bool escape)
{
    AIFloat3 from=unit->GetPos(ai->GetLastFrame());
    const float margin=unit->GetCircuitDef()->GetRangedPolicy().safetyMargin;
    const size_t first=(&route==&path)?pathCursor:0;
    for(size_t i=first;i<route.size();++i) {
        const auto& p=route[i];
        if(from.SqDistance2D(p)<16.f) continue;
        if(!SafeMove(unit,from,p,margin,escape)) return false;
        from=p;
    }
    return true;
}

void CRangedEngagement::Disperse(CCircuitUnit* unit)
{
    const auto pos=unit->GetPos(ai->GetLastFrame());
    const auto& policy=unit->GetCircuitDef()->GetRangedPolicy();
    // Finishing the last target must not cancel a formation move and leave
    // explosive hulls packed together. Continue only the previously validated
    // route (Update rechecks its coverage). A rear-only idle rule was tested
    // and rejected: it reduced Starlight bait clearance from nine to two,
    // without improving closing-assault survival. See D-207's played record.
    if (query || moving) return;
    if (world.FreeSlot(id,pos,policy.spacing)) {
        world.SetSlot(id,pos,policy.spacing,unit->GetCircuitDef()->GetCostM());
        return;
    }
    for (int ring=1;ring<=3;++ring) for (int i=0;i<16;++i) {
        const float angle=(i+(id%16))*.3926990817f;
        AIFloat3 point=pos+AIFloat3(std::cos(angle),0.f,std::sin(angle))*policy.spacing*float(ring);
        CTerrainManager::CorrectPosition(point);
        point.y=ai->GetTerrainManager()->GetAreaData()->GetElevationAt(point.x,point.z);
        if (world.FreeSlot(id,point,policy.spacing) && world.Safe(pos,point,policy.safetyMargin,true,policy.pressStatic)
            && world.DangerSign(point,policy.safetyMargin,policy.pressStatic)==0.f
            && ai->GetTerrainManager()->CanMoveToPos(unit->GetArea(),point)) {
            Move(unit,point,true); return;
        }
    }
}
bool CRangedEngagement::Move(CCircuitUnit* unit,const AIFloat3& dest,bool escape)
{
    const auto& policy=unit->GetCircuitDef()->GetRangedPolicy();
    const auto pos=unit->GetPos(ai->GetLastFrame());
    bool reusable=true;
    if(policy.sustainedRush && world.IsSustainedRush(id)) {
        const auto& plan=world.PlanCohort(unit);
        if(plan.sustainedRush && plan.target>=0 && (dest.x-pos.x)*(plan.focus.x-pos.x)
            +(dest.z-pos.z)*(plan.focus.z-pos.z)<-1.f) {
            ai->LOG("[INVARIANT] INV-197 sustained rush received a backward combat destination unit=%d",id);
            Hold(unit,true);
            return false;
        }
        reusable=!plan.sustainedRush || (destination.x-pos.x)*(plan.focus.x-pos.x)
            +(destination.z-pos.z)*(plan.focus.z-pos.z)>=0.f;
    }
    if(pos.SqDistance2D(dest)<32.f*32.f) { Hold(unit); return false; }
    const bool same=destination.SqDistance2D(dest)<policy.hysteresis*policy.hysteresis;
    if(reusable && same && query) return true;
    if(reusable && same && moving && ai->GetUnitAPI()->GetCMDQueueSize(id)>0 && LegalPath(unit,path,escape)) return true;
    if(reusable && policy.coordinated && policy.intentGain>0.f && !urgentMove && moving
        && cohort::KeepMove(P(pos),P(destination),P(dest),policy.intentGain,policy.spacing)
        && ai->GetUnitAPI()->GetCMDQueueSize(id)>0 && LegalPath(unit,path,escape)) return true;
    if(reusable && policy.coordinated && moving && ai->GetUnitAPI()->GetCMDQueueSize(id)>0 && LegalPath(unit,path,escape)) {
        const AIFloat3 live=destination-pos, wanted=dest-pos;
        const float product=live.x*wanted.x+live.z*wanted.z;
        // Preserve a live move that still advances the same local intent.
        // Receding target coordinates alone should not rebuild the command
        // queue. A changed heading, shorter goal or fresh danger still wins.
        if(live.SqLength2D()>4096.f && wanted.SqLength2D()>=live.SqLength2D()
            && product>0.f && product*product>.94f*live.SqLength2D()*wanted.SqLength2D()) return true;
    }
    // Owner 2026-10-19: a live, still-legal move is replaced at most once per
    // move_min_seconds; danger (urgent), escapes and an idle unit go at once.
    // Kiting units were re-moved on every 8-frame decision (cortrem 2.5/s).
    if(!urgentMove && !escape && moving && policy.moveMinSeconds>0.f
        && ai->GetLastFrame()<lastMoveFrame+int(policy.moveMinSeconds*FRAMES_PER_SEC)
        && ai->GetUnitAPI()->GetCMDQueueSize(id)>0 && LegalPath(unit,path,escape)) return true;
    if(!ai->GetTerrainManager()->CanMoveToPos(unit->GetArea(),dest) || !SafeMove(unit,pos,dest,policy.safetyMargin,escape)) return false;
    if(trace) ai->LOG("RANGED: move-replace unit=%d objective=%d mode=%d urgent=%d moving=%d pending=%d queue=%d from=%.1f,%.1f old=%.1f,%.1f new=%.1f,%.1f",
        id,moveObjective,moveMode,int(urgentMove),int(moving),int(query!=nullptr),
        ai->GetUnitAPI()->GetCMDQueueSize(id),pos.x,pos.z,destination.x,destination.z,dest.x,dest.z);
    completedMove=false;
    destination=dest; query.reset(); const unsigned version=++generation; lastMoveFrame=ai->GetLastFrame();
    world.SetSlot(id,dest,policy.spacing,unit->GetCircuitDef()->GetCostM());
    auto* finder=ai->GetPathfinder();
    if(policy.coordinated && pos.SqDistance2D(dest)<=1024.f*1024.f) {
        // Kiting cannot wait for a worker path and then replay its start
        // waypoint. Prove a short local segment on the movement/threat grid;
        // A bounded local formation approach can use one engine MOVE instead
        // of emitting every worker waypoint. Difficult terrain falls through
        // to the validated asynchronous path; this never skips the line test.
        auto line=std::static_pointer_cast<CQueryLineMap>(finder->CreateLineMapQuery(unit,ai->GetThreatMap(),pos));
        if(line->IsSafeLine(pos,dest)) {
            path.assign(1,dest); pathCursor=0; moving=true; issuing=true;
            TRY_UNIT(ai,unit,unit->CmdMoveTo(dest);)
            issuing=false; return true;
        }
    }
    // Single-query radii are truncated to path-grid cells. A sub-cell radius
    // becomes zero and MicroPather fails immediately; use one cell, then
    // append and validate the exact formation slot as the final short leg.
    query=finder->CreatePathSingleQuery(unit,ai->GetThreatMap(),pos,dest,float(finder->GetSquareSize()));
    const std::weak_ptr<int> alive=lifetime;
    finder->RunQuery(ai->GetScheduler().get(),query,[this,alive,version,escape,dest](const IPathQuery* result) {
        if(alive.expired()) return;
        auto* unit=ai->GetTeamUnit(id);
        if(!unit || unit->GetTask()!=owner || version!=generation || result!=query.get()) {
            if(trace) ai->LOG("RANGED: obsolete path unit=%d owner=%d generation=%d query=%d",id,
                unit && unit->GetTask()==owner,int(version==generation),int(result==query.get()));
            return;
        }
        auto points=static_cast<const CQueryPathSingle*>(result)->GetPathInfo()->posPath;
        world.Refresh();
        if(world.IsSustainedRush(id)) {
            const auto& plan=world.PlanCohort(unit);
            const auto current=unit->GetPos(ai->GetLastFrame());
            // A moving front can invalidate a forward goal while its worker
            // path is pending. Drop that result on the callback thread.
            if(plan.sustainedRush && (dest.x-current.x)*(plan.focus.x-current.x)
                +(dest.z-current.z)*(plan.focus.z-current.z)<0.f) {
                Hold(unit,true); return;
            }
        }
        const bool solved=!points.empty();
        if(trace) ai->LOG("RANGED: path completed unit=%d generation=%u points=%u",id,version,unsigned(points.size()));
        if(solved) ranged::AppendExactGoal(points,dest);
        if(unit->GetCircuitDef()->GetRangedPolicy().coordinated) ranged::CompactStraightRoute(points);
        else if (points.size() > 2) {
            // Geometry is independent of composition policy: precision guns
            // also receive long grid routes. Preserve joins/bends/reversals,
            // validate original straight legs on the current movement/threat
            // grid, then retain the existing whole-route combat safety test.
            // O(points + sampled leg length); no new decision cadence or APM
            // limit. Failed legs fence only their neighboring straight run.
            auto line = std::static_pointer_cast<CQueryLineMap>(ai->GetPathfinder()->CreateLineMapQuery(
                unit, ai->GetThreatMap(), unit->GetPos(ai->GetLastFrame())));
            ranged::CompactValidatedStraightRoute(points, [&](const AIFloat3& from, const AIFloat3& to) {
                return line->IsSafeLine(from,to);
            });
        }
        if(points.size()>1 && points.back().SqDistance2D(points[points.size()-2])<17.f*17.f)
            ai->LOG("[INVARIANT] INV-167 ranged exact endpoint would cancel its queued predecessor unit=%d",id);
        if(!solved || !LegalPath(unit,points,escape)) {
            if(trace) ai->LOG("RANGED: path rejected unit=%d points=%u",id,unsigned(points.size()));
            query.reset(); orientUntil=0; ++failures; ++rejections; return;
        }
        // Validate the actual worker path, then every continued route against
        // fresh coverage. No engine callbacks run on path worker threads.
        path=points; pathCursor=0; query.reset(); moving=true; issuing=true;
        TRY_UNIT(ai,unit,
            for(size_t i=0;i<path.size();++i) unit->CmdMoveTo(path[i],i?UNIT_COMMAND_OPTION_SHIFT_KEY:0);
        )
        issuing=false;
    });
    return true;
}

void CRangedEngagement::UpdateCohort(CCircuitUnit* unit)
{
    const int frame=ai->GetLastFrame();
    const auto pos=unit->GetPos(frame);
    auto* def=unit->GetCircuitDef(); const auto& policy=def->GetRangedPolicy();
    const auto& group=world.PlanCohort(unit);
    const auto member=std::find(group.members.begin(),group.members.end(),id);
    if(member==group.members.end() || group.members.size()>size_t(policy.cohortSize)) {
        ai->LOG("[INVARIANT] INV-166 coordinated unit has invalid cohort membership unit=%d",id); return;
    }
    if(group.target<0 && group.mode==cohort::Mode::HOLD) {
        // Cancel the old approach when a protected contact leaves vision.
        // Otherwise Disperse deliberately preserves that in-flight move.
        if(policy.engagementSeconds>0.f && group.protectedTarget>=0) {
            Hold(unit,true); SelectTarget(unit,-1,-1,0.f);
            world.SetSlot(id,pos,policy.spacing,def->GetCostM());
            return;
        }
        // Preserve the completed firing line. Fresh observed objectives are
        // still considered by PlanCohort on every decision; this is not a timer
        // or an aggression cap. Existing movement can finish and hulls disperse.
        SelectTarget(unit,-1,-1,0.f);
        Disperse(unit);
        return;
    }
    const int rank=int(member-group.members.begin());
    float maxRange=0.f; for(const auto& w:caps.weapons) maxRange=std::max(maxRange,w.range);
    world.Nearby(pos,maxRange+600.f,nearby);
    const auto& contacts=world.Contacts();
    const bool assessed=policy.engagementSeconds>0.f;
    float rawVelocity[3]={};
    if(assessed) ai->GetUnitAPI()->GetVelocity(id,rawVelocity);
    const AIFloat3 velocity(rawVelocity[0]*FRAMES_PER_SEC,0.f,rawVelocity[2]*FRAMES_PER_SEC);
    int best=-1,weapon=-1; float score=-1.f,damage=0.f;
    const CRangedWorld::Contact* danger=nullptr; float penetration=0.f;
    const CRangedWorld::Contact* incoming=nullptr;
    const CRangedWorld::Contact* objective=nullptr;
    for(int i:nearby) {
        const auto& c=contacts[i];
        if(c.id==group.target) objective=&c;
        if(!c.def || c.def->IsAbleToFly() || c.pos.y< -20.f) continue;
        // The local escape decision remains individual: a centroid must not
        // hide a flank being overrun. Mobile exposure is allowed only during
        // an approved rush; sustained commitment deliberately spends against
        // both mobile and static exposure after local force admission.
        const float distance=std::sqrt(pos.SqDistance2D(c.pos));
        const float enemyClosing=ranged::ClosingSpeed(P(pos),P(c.pos),P(c.velocity));
        const float relativeClosing=assessed?cohort::RelativeClosing(P(pos),P(velocity),P(c.pos),P(c.velocity)):enemyClosing;
        // Brake before our own advance consumes the range advantage. An
        // unfavorable fight retains the conservative escape prediction once
        // withdrawing; a committed favorable kite uses actual separation.
        const bool narrowKite=assessed && c.mobile && c.groundRange<maxRange
            && !cohort::ShortKite(maxRange,c.groundRange,def->GetSpeed(),policy.reactionSeconds);
        const float closing=narrowKite?enemyClosing:
            assessed && group.committed?relativeClosing:std::max(enemyClosing,relativeClosing);
        if(c.armed && c.mobile && c.groundRange<maxRange && closing>1.f
            && distance<maxRange+64.f+(narrowKite?0.f:std::max(0.f,closing-enemyClosing)*policy.reactionSeconds)) incoming=&c;
        // Rear elements anticipate closing threats earlier, without forcing
        // their screen to wait. SET_TARGET remains active during this movement,
        // so a ready rocket can fire and its reload is useful escape time.
        const float anticipation=policy.reactionSeconds
            +(group.formationRear ? policy.withdrawalLeadSeconds : 0.f);
        float reach=c.hazardRadius+policy.safetyMargin+closing*anticipation;
        // Predict relative to the screen's band. Without its depth, the rear's
        // extra second merely consumes part of its range advantage and can
        // still start withdrawing AFTER the screen. Stationary threats do not
        // gain this buffer: that would prevent a safe rocket siege.
        if(group.formationRear && c.mobile && enemyClosing>0.f)
            reach+=group.formationScreenOffset;
        const float reclaim=assessed && c.def->IsAbleToReclaim()?c.def->GetBuildDistance()+c.radius+policy.safetyMargin:0.f;
        reach=std::max(reach,reclaim);
        const bool approvedStatic=assessed && group.committed
            && std::find(group.assault.begin(),group.assault.end(),c.id)!=group.assault.end();
        const bool approvedMobile=c.mobile && !c.def->IsEnemyRoleAny(CCircuitDef::COMM)
            && group.mode==cohort::Mode::RUSH && (!assessed || c.groundRange>=maxRange
                || (policy.supportAllies && group.supporting
                    && distance>c.groundRange+policy.safetyMargin));
        if((c.hazardRadius>0.f || reclaim>0.f) && distance<reach && reach-distance>penetration
            && (distance<reclaim || !(approvedStatic || approvedMobile))) {
            danger=&c; penetration=reach-distance;
        }
        // Target permissions never suppress the hazard above. Coordinated
        // movement is opt-in, but still honors existing JSON target controls.
        if(c.mobile?!policy.allowMobile:!policy.allowStatic) continue;
        if(policy.avoidCategory & c.def->GetCategory()) continue; // D-294
        for(size_t wi=0;wi<caps.weapons.size();++wi) {
            const auto& w=caps.weapons[wi];
            if(!(w.category&c.def->GetCategory()) || (!c.los && !policy.allowRadar)) continue;
            const float range=world.Range(w,pos,c.pos);
            if(distance>range || !world.Trajectory(w,pos,c.pos)
                || world.FriendlySplash(id,c.pos,std::max(w.splash,c.explosionRadius))
                || world.FriendlyLine(w,id,pos,c.pos)) continue;
            const float hit=c.armor>=0 && size_t(c.armor)<w.damage.size()?w.damage[c.armor]*w.alphaScale:0.f;
            if(hit<=0.f) continue;
            // Value per remaining HP favors killable repair support in range.
            // It never licenses movement past the firing line to chase it.
            float s=(1.f+c.cost)/std::max(hit,c.health)*world.Progress(c.id,policy.repairedTargetPenalty);
            if(c.def->IsBuilder()) s*=2.f;
            if(c.id==target) s*=policy.targetHysteresis;
            if(world.Reserved(c.id,id)>=c.health) s*=.2f;
            if(s>score) { score=s; best=i; weapon=int(wi); damage=hit; }
        }
    }
    auto point=group.focus;
    if(group.target>=0) {
        const auto arc=cohort::Arc(P(group.focus),P(group.back),group.radius,rank,int(group.members.size()),policy.spacing);
        point.x=arc.x; point.z=arc.z;
        if(group.formationRear) {
            point.x-=group.back.z*policy.spacing*.5f;
            point.z+=group.back.x*policy.spacing*.5f;
        }
    } else {
        // Keep separate lanes during travel as well as at the firing band.
        // Keep a rounding margin between adjacent straight-line reservations,
        // just as Arc does for chord distance. Exact float spacing can round
        // below FreeSlot's strict boundary and churn between lateral slots.
        const float offset=(rank-(group.members.size()-1)*.5f)*(policy.spacing+1.f);
        point+=AIFloat3(-group.back.z,0,group.back.x)*offset;
    }
    if(group.sustainedRush) { danger=nullptr; incoming=nullptr; withdrawalUntil=0; }
    if(danger) {
        AIFloat3 away=pos-danger->pos; away.Normalize2D();
        if(away.SqLength2D()<.5f) away=group.back;
        const bool disengage=!group.committed || group.mode==cohort::Mode::WITHDRAW || !danger->mobile
            || danger->def->IsEnemyRoleAny(CCircuitDef::COMM) || danger->def->IsAbleToReclaim()
            || (!(policy.supportAllies && group.supporting)
                && !cohort::ShortKite(maxRange,danger->groundRange,def->GetSpeed(),policy.reactionSeconds));
        // The engine accepts arrival short of the exact endpoint. A 32-elmo
        // escape can therefore complete before the hull actually gets clear.
        // Leave one movement cell of usable travel beyond that tolerance.
        point=pos+away*(assessed?std::max(96.f,cohort::KiteStep(penetration,policy.hysteresis,disengage))
            :std::max(192.f,penetration+policy.hysteresis));
        withdrawalUntil=assessed && !disengage?frame+15:frame+30;
    } else if(frame<withdrawalUntil && moving) {
        SelectTarget(unit,best>=0?contacts[best].id:-1,weapon,damage);
        return;
    } else if(incoming && !(policy.supportAllies && group.supporting && group.committed)
        && point.SqDistance2D(incoming->pos)<pos.SqDistance2D(incoming->pos)) {
        // Hold the line when a shorter-ranged enemy is already approaching.
        // Advancing into it doubles closure and spends the entire range
        // advantage turning around. Let it enter our fire before pulling back.
        point=pos;
    } else if(best>=0 && !group.sustainedRush && !group.rushFallback && !group.formationRear && (assessed || group.mode!=cohort::Mode::REGROUP)
        && world.FreeSlot(id,pos,policy.spacing)
        && !(policy.supportAllies && group.supporting && group.committed
            && (pos.x-group.focus.x)*group.back.x+(pos.z-group.focus.z)*group.back.z>group.screenDepth+policy.spacing)) {
        // A safe, spaced shooter already contributes to the firing line.
        // Do not chase the ideal arc coordinate while it has a legal shot:
        // that spends movement orders and firing time without adding damage.
        // Danger/regrouping above override immediately; blocked rear members
        // still advance to their shared slots until they too can contribute.
        point=pos;
    }
    if(!danger && best<0 && objective && pos.SqDistance2D(point)<4096.f
        && (group.mode==cohort::Mode::ADVANCE || group.mode==cohort::Mode::RUSH)) {
        const float distance=std::sqrt(pos.SqDistance2D(objective->pos));
        const float reach=world.Range(caps.weapons.front(),pos,objective->pos);
        if(distance>reach && distance-reach<64.f) {
            // Engine arrival can stop 32 elmos before a firing slot. A unit
            // just outside range must take the remaining step, not consider
            // itself settled forever. The next legal shot holds it immediately;
            // mobile danger and static/terrain validation still take precedence.
            point=pos+(objective->pos-pos)*((distance-reach+32.f)/distance);
        }
    }
    CTerrainManager::CorrectPosition(point);
    // Advancing enemies can move the ideal firing arc behind a committed
    // shooter. Hold and fire in that case instead of backing out to the arc.
    // This is a combat-goal constraint, not a change to terrain pathfinding.
    if(group.sustainedRush && (point.x-pos.x)*(group.focus.x-pos.x)
        +(point.z-pos.z)*(group.focus.z-pos.z)<0.f) point=pos;
    point.y=ai->GetTerrainManager()->GetAreaData()->GetElevationAt(point.x,point.z);
    bool safe=SafeMove(unit,pos,point,policy.safetyMargin,true);
    if(!safe && !danger) {
        // Bounded staging search along the same approach: stop before static
        // coverage instead of remaining at the distant spawn or diving at bait.
        const AIFloat3 delta=point-pos;
        for(int k=3;k>=1;--k) {
            AIFloat3 stage=pos+delta*(k*.25f);
            if(pos.SqDistance2D(stage)>4096.f && SafeMove(unit,pos,stage,policy.safetyMargin,false)) {
                point=stage; safe=true; break;
            }
        }
    }
    // Move considers a point within 32 elmos reached. Use the same tolerance
    // here: otherwise its successful HOLD looks like a failed placement and
    // the next lateral candidate immediately orders another MOVE.
    const float arrival=std::max(group.target<0?64.f:32.f,policy.hysteresis);
    // A formation deliberately staged outside an immobile battery has no
    // legal shot. Requiring one here makes adjacent cohorts repeatedly trade
    // lateral slots. Retain only a reached, still-safe nearby reservation for
    // the SAME objective/mode; danger and fresh movement admission win above.
    const bool formationStaging=policy.formationPosition!=RangedPolicy::FormationPosition::NONE
        && group.mode==cohort::Mode::WITHDRAW && objective && !objective->mobile
        && moveObjective==group.target && moveMode==int(group.mode);
    // Recoil may finish a MOVE before its exact endpoint. The route walker
    // already accepts its final waypoint within 64 elmos; repeatedly sending
    // that completed command buys no progress. Adopt the reached position only
    // for safe static staging, using the existing route/slot tolerances. This
    // is not an arrival relaxation for attacks, retreats or failed commands:
    // fresh danger, objective/mode changes and spacing all invalidate reuse.
    const bool completedStage=formationStaging && completedMove && !danger && best<0
        && cohort::CompletedStage(P(pos),P(destination),P(point),policy.spacing)
        && world.FreeSlot(id,pos,policy.spacing)
        && SafeMove(unit,pos,pos,policy.safetyMargin,false);
    if(completedStage) point=pos;
    if(!completedStage && !danger && group.mode!=cohort::Mode::REGROUP
        && destination.SqDistance2D(point)<4.f*policy.spacing*policy.spacing
        && pos.SqDistance2D(destination)<arrival*arrival
        && ((!group.sustainedRush && !group.rushFallback && best>=0) || group.target<0 || (formationStaging
            && SafeMove(unit,pos,destination,policy.safetyMargin,false)))
        && world.FreeSlot(id,destination,policy.spacing)) point=destination;
    urgentMove=danger || moveObjective!=group.target || moveMode!=int(group.mode);
    moveObjective=group.target; moveMode=int(group.mode);
    const bool settled=pos.SqDistance2D(point)<arrival*arrival;
    if(safe && !settled) {
        // Formation slots may overlap another cohort's arc. Try a few lateral
        // alternatives; bound work and retain static-path checks in Move.
        bool placed=false;
        for(int k=0;k<5;++k) {
            const int side=k==0?0:(k%2?(k+1)/2:-k/2);
            AIFloat3 candidate=point+AIFloat3(-group.back.z,0,group.back.x)*(side*(policy.spacing+1.f));
            CTerrainManager::CorrectPosition(candidate);
            if(group.sustainedRush && (candidate.x-pos.x)*(group.focus.x-pos.x)
                +(candidate.z-pos.z)*(group.focus.z-pos.z)<0.f) continue;
            candidate.y=ai->GetTerrainManager()->GetAreaData()->GetElevationAt(candidate.x,candidate.z);
            if(world.FreeSlot(id,candidate,policy.spacing) && Move(unit,candidate,true)) { placed=true; break; }
        }
        // Spacing is subordinate to survival. A reserved retreat slot must not
        // leave the previous forward MOVE running into a closing assault.
        // Keep terrain/static validation, but allow a temporary crowded escape.
        if(!placed && danger) {
            placed=Move(unit,point,true);
            if(!placed) Hold(unit,true);
        }
        // Commitment disables retreat, not physical firing lanes. Forcing an
        // occupied rush goal crowds friendly splash weapons into each other.
        // Keep firing and retry the bounded forward slots next decision.
        if(!placed && group.sustainedRush) Hold(unit,true);
        if(!placed && !moving) world.SetSlot(id,pos,policy.spacing,def->GetCostM());
    } else if(settled || !safe) {
        Hold(unit,true); world.SetSlot(id,settled?point:pos,policy.spacing,def->GetCostM());
    }
    // MOVE plus BAR SET_TARGET permits firing while kiting without an ATTACK
    // order overriding the shared line. STOP above clears BAR priority target,
    // so repair it in the same decision after applying movement.
    SelectTarget(unit,best>=0?contacts[best].id:-1,weapon,damage);
    if(trace && frame>=traceFrame+150) {
        traceFrame=frame;
        ai->LOG("COHORT: unit=%d members=%u mode=%d target=%d radius=%.0f dest=%.0f,%.0f danger=%d reason=%d loss=%.3f advantage=%.3f committed=%d supporting=%d screen=%.0f",
            id,unsigned(group.members.size()),int(group.mode),group.target,group.radius,point.x,point.z,danger?danger->id:-1,
            int(group.reason),group.loss,group.advantage,int(group.committed),int(group.supporting),group.screenDepth);
    }
}

void CRangedEngagement::Update(CCircuitUnit* unit)
{
    const int frame=ai->GetLastFrame();
    if(released || issuing || frame<nextFrame || unit->Blocker()) return;
    performance::Scope measured(ai,performance::RANGED_DECISION);
    nextFrame=frame+8; // decision sampling, not an order/APM limit; damage/idle invalidates
    world.Refresh();
    auto* def=unit->GetCircuitDef(); const auto& policy=def->GetRangedPolicy();
    const auto pos=unit->GetPos(frame);
    if(caps.weapons.empty()) return;
    // Discard already traversed waypoints. Validating a route back to its old
    // start incorrectly rejects a successful escape as renewed exposure.
    while(pathCursor<path.size() && (pos.SqDistance2D(path[pathCursor])<4096.f
        || (pathCursor+1<path.size() && pos.SqDistance2D(path[pathCursor+1])<pos.SqDistance2D(path[pathCursor])))) ++pathCursor;
    if(moving && !LegalPath(unit,path,true)) { Hold(unit,true); assistCheckFrame=-1; }
    if(moving && ai->GetUnitAPI()->GetCMDQueueSize(id)==0) {
        completedMove=!path.empty() && pathCursor==path.size()
            && pos.SqDistance2D(destination)<4096.f;
        moving=false; path.clear(); pathCursor=0;
    }
    if(assistCheckFrame>=0) {
        // INV-206: an accepted assist Move leaves the unit moving or with a
        // pending worker query by its next decision. A rejected worker path or
        // MoveFailed counts a failure; a fresh danger hold clears the check.
        // The engine may also finish or drop a MOVE within one decision (an
        // engine refusal this controller cannot tell from a lost command), so
        // only three consecutive accepted moves that each left the unit idle
        // are reported (8v8 20261014T015406Z: 30 single-decision hits).
        if(!moving && !query && rejections==assistCheckRejections
            && pos.SqDistance2D(destination)>128.f*128.f) {
            if(++assistIdleStreak>=3 && !assistInvariantLogged) {
                ai->LOG("[INVARIANT] INV-206 ranged assist moves accepted but unit %d stays neither moving nor querying",id);
                assistInvariantLogged=true;
            }
        } else assistIdleStreak=0;
        assistCheckFrame=-1;
    }

    if(liveWeapon) {
        const int reload=liveWeapon->GetReloadFrame();
        if(reload>lastReload && lastReload>=0) {
            lastShotFrame=frame; failures=0;
            orientUntil=0; // Actual fire completes facing recovery immediately.
            burstUntil=frame+int(caps.weapons[weaponIndex].burst*30.f)+3;
            world.ReserveShot(id,target,reservedDamage,std::min(reload,frame+90));
        }
        lastReload=reload;
    }
    if(caps.cloak && policy.cloakOnReload) {
        const float energy=ai->GetEconomyManager()->GetEnergyCur();
        const float shot=weaponIndex>=0 && caps.weapons[weaponIndex].def ? caps.weapons[weaponIndex].def->GetCostEShot() : 500.f;
        const bool wanted=energy>shot+(moving?caps.cloakMoving:caps.cloakCost)*policy.cloakReserve;
        if(wanted!=cloakWanted) { TRY_UNIT(ai,unit,unit->CmdCloak(wanted);) cloakWanted=wanted; }
    }
    if(policy.coordinated) { UpdateCohort(unit); return; }
    float maxRange=0.f;
    for(const auto& w:caps.weapons) maxRange=std::max(maxRange,w.range);
    world.Nearby(pos,maxRange+1000.f,nearby);
    const auto& contacts=world.Contacts();
    const bool report=trace && frame>=traceFrame+150;
    if(report) { traceFrame=frame; ai->LOG("RANGED: sample unit=%d contacts=%u near=%u range=%.1f",id,unsigned(contacts.size()),unsigned(nearby.size()),maxRange); }

    const CRangedWorld::Contact* closing=nullptr;
    float urgency=0.f;
    const bool forward=std::any_of(caps.weapons.begin(),caps.weapons.end(),[](const auto& w){return w.forward;});
    const float escapeSeconds=ranged::EscapeSeconds(caps.speed,caps.turnRate,caps.acceleration,forward,policy.reactionSeconds);
    for(int i:nearby) {
        // Owner 2026-10-19: a pressed static defence is fought, not escaped;
        // only its death blast still pushes the hull back.
        const auto& c=contacts[i]; const float hazard=CRangedWorld::HazardFor(c,policy.pressStatic);
        if(hazard<=0.f) continue;
        // D-294: escaping a much faster avoided contact (Tick) is futile and
        // only spends MOVEs. It remains a hazard for Safe/DangerSign below.
        if(c.def && (c.def->GetCategory()&policy.avoidCategory)) continue;
        const float d=std::sqrt(pos.SqDistance2D(c.pos));
        const float closingSpeed=ranged::ClosingSpeed(P(pos),P(c.pos),P(c.velocity));
        const float reach=hazard+policy.safetyMargin+closingSpeed*escapeSeconds;
        if(d<reach && reach-d>urgency) { closing=&c; urgency=reach-d; }
    }
    if(!policy.holdFireline && (closing || frame<withdrawalUntil)) {
        if(closing && !(frame<withdrawalUntil && moving)) {
            AIFloat3 away=pos-closing->pos;
            if(away.SqLength2D()<1.f) away=AIFloat3(1.f,0.f,0.f);
            away.Normalize2D();
            const float separation=std::max(160.f,urgency+policy.hysteresis);
            AIFloat3 escape=pos+away*std::min(600.f,separation);
            CTerrainManager::CorrectPosition(escape);
            escape.y=ai->GetTerrainManager()->GetAreaData()->GetElevationAt(escape.x,escape.z);
            if(world.Safe(pos,escape,policy.safetyMargin,true,policy.pressStatic)) {
                // Forward-arc hulls commit to their exit; unrestricted turrets
                // may retain a safe pursuer as target while MOVE remains owner.
                if(forward) { SelectTarget(unit,-1,-1,0.f); reorient=true; }
                orientUntil=0; // A newly closing threat preempts facing recovery.
                withdrawalUntil=frame+std::max(30,int(escapeSeconds*30.f));
                Move(unit,escape,true);
            }
        }
        if(forward) return;
    }

    if (policy.holdFireline && closing) {
        Hold(unit,true);
        withdrawalUntil=0;
    }
    int best=-1,bestWeapon=-1; float bestScore=-1.f,bestDamage=0.f;
    for(int i:nearby) {
        const auto& c=contacts[i];
        if(!c.los && !policy.allowRadar) continue;
        if((c.mobile && !policy.allowMobile)||(!c.mobile && !policy.allowStatic)) continue;
        // D-294 (owner correction): artillery and radar are a pairing, so a
        // blind shot at a slow or stationary dot stays valid. Identified avoided
        // categories are excluded here; an unidentified dot too fast for the
        // shell is excluded below by the same evasion arithmetic.
        if(c.def && (c.def->GetCategory()&policy.avoidCategory)) continue; // O(1)
        for(size_t wi=0;wi<caps.weapons.size();++wi) {
            const auto& w=caps.weapons[wi];
            if((c.def && !(w.category&c.def->GetCategory())) || c.pos.y< -20.f) continue;
            const float range=world.Range(w,pos,c.pos);
            if(pos.SqDistance2D(c.pos)>range*range || !world.Trajectory(w,pos,c.pos)) continue;
            // Destroying energy storage can kill nearby allies even when our
            // own weapon is precise. Keep clear of its loaded death blast and
            // withhold the shot until the exposed cohort can leave it.
            if(c.explosionRadius>0.f && pos.SqDistance2D(c.pos)<std::pow(c.explosionRadius+caps.radius,2.f)) continue;
            if(world.FriendlySplash(id,c.pos,std::max(w.splash,c.explosionRadius))) continue;
            if(world.FriendlyLine(w,id,pos,c.pos)) continue;
            const int armor=c.armor;
            const float damage=policy.mode==RangedPolicy::Mode::CARRIER?c.health:
                (armor>=0 && size_t(armor)<w.damage.size()?w.damage[armor]*w.alphaScale:0.f);
            if(damage<=0.f) continue;
            // A legal unidentified radar dot is a low-priority blind shot,
            // never an invented heavy identity, HP estimate or threat source.
            float value=c.def ? ranged::UsefulScore(c.cost,c.health,damage,world.Reserved(c.id,id),policy.mode==RangedPolicy::Mode::PRECISION,
                policy.preferHeavy && c.def->IsEnemyRoleAny(CCircuitDef::HEAVY|CCircuitDef::COMM),c.los,world.Progress(c.id,policy.repairedTargetPenalty)) : .01f/(1.f+world.Reserved(c.id,id));
            if(c.def && policy.mode!=RangedPolicy::Mode::PRECISION)
                value+=policy.splashWeight*std::max(0.f,world.ClusterValue(c.pos,w.splash)-c.cost);
            // D-294: opt-in hit-likelihood test for slow shells against fast
            // targets. Identified: a 0.05 penalty (with nothing better the shot
            // is still taken). Unidentified dot for an avoid-category shooter:
            // excluded, since a dot that fast cannot be told from a scout and
            // the played run spent 7-second shells on running Ticks. A dot's
            // velocity comes from the radar track; one sample reads as
            // stationary. O(1) per candidate mount.
            const bool evasive=policy.evasionLimit>0.f && c.mobile && ranged::Evasive(std::sqrt(pos.SqDistance2D(c.pos)),w.speed,
                std::sqrt(c.velocity.x*c.velocity.x+c.velocity.z*c.velocity.z),w.splash,c.radius,policy.evasionLimit);
            if(evasive && !c.def && policy.avoidCategory!=0) continue;
            if(evasive) value*=.05f;
            if(c.id==target) value*=policy.targetHysteresis;
            if(policy.mode==RangedPolicy::Mode::BOMBARDMENT && !c.mobile) value*=1.5f;
            if(closing && closing->id==c.id) value*=2.f;
            // Owner 2026-10-19: the tower shooting at a pressing hull comes first.
            if(CRangedWorld::Pressed(c,policy.pressStatic)) value*=2.f;
            if(value>bestScore || (value==bestScore && (best<0 || c.id<contacts[best].id))) {
                best=i; bestWeapon=int(wi); bestScore=value; bestDamage=damage;
            }
        }
    }
    if(best>=0) {
        const auto& c=contacts[best];
        SelectTarget(unit,c.id,bestWeapon,bestDamage);
        if(frame<withdrawalUntil) return;
        const float spacing=policy.spacing;
        if(frame<orientUntil) return;
        // An energy-starved shot is not evidence of a blocked firing lane.
        // Repositioning cannot solve the shortage and only creates churn.
        const auto* selectedWeapon=caps.weapons[bestWeapon].def;
        const bool funded=!selectedWeapon || ai->GetEconomyManager()->GetEnergyCur()>=selectedWeapon->GetCostEShot();
        const bool stalled=funded && policy.mode!=RangedPolicy::Mode::CARRIER && frame-lastShotFrame>
            int((caps.weapons[bestWeapon].reload+8.f)*30.f);
        if(reorient || (forward && stalled)) {
            // D-226: SET_TARGET selects a weapon target, not hull facing. An
            // in-range target behind a forward mount can therefore remain
            // passive forever. Moving back to the outer firing band faces
            // away again; the next decision also used to STOP that move.
            // Reuse withdrawal's short, safety-checked facing step and let it
            // finish. Real fire, new danger and the bounded deadline still
            // interrupt it. This is one local candidate, not another scan.
            AIFloat3 facing=c.pos-pos; facing.Normalize2D(); auto point=pos+facing*64.f;
            if(world.Safe(pos,point,policy.safetyMargin,false,policy.pressStatic) && world.FreeSlot(id,point,spacing)
                && Move(unit,point,false)) {
                orientUntil=frame+std::max(30,int(escapeSeconds*30.f));
                lastShotFrame=frame;
                reorient=false;
                if(trace) ai->LOG("RANGED: face unit=%d target=%d until=%d",id,c.id,orientUntil);
                return;
            }
            reorient=false;
        }
        if(world.FreeSlot(id,pos,spacing) && !stalled) {
            Hold(unit);
            SelectTarget(unit,c.id,bestWeapon,bestDamage);
            world.SetSlot(id,pos,spacing,def->GetCostM());
            return;
        }
        if(stalled) { ++failures; lastShotFrame=frame; }
        if(frame<burstUntil) return;
    } else SelectTarget(unit,-1,-1,0.f);
    if (policy.holdFireline && closing) {
        world.SetSlot(id,pos,policy.spacing,def->GetCostM());
        return; // A facing gun remains useful; turning away cannot create fire.
    }
    if(frame<withdrawalUntil || frame<burstUntil) return;

    // Stable target-centered firing bands. Candidate work is bounded (17 sites
    // per objective), and local formation queries avoid pairwise unit scans.
    // Borrow frame-local candidates; preserve their order/ties without a
    // heap-allocated vector copy for each unit every eight frames.
    const auto& choices=nearby.empty() ? world.Objectives() : nearby;
    float nearest=std::numeric_limits<float>::max(); int objective=-1;
    int unknownObjectives=0;
    const auto consider=[&](int i) {
        const auto& c=contacts[i];
        if (policy.holdFireline && !c.los) return;
        // A radar dot permits a blind shot, not an invented threat estimate.
        // Precision hulls can opt out of advancing before vision identifies
        // the contact; otherwise they walk into fast assault while arranging
        // a firing band around an apparently harmless unknown target.
        if(!c.def && !policy.advanceUnknownRadar) { ++unknownObjectives; return; }
        if((c.def && c.def->IsAbleToFly()) || (c.mobile?!policy.allowMobile:!policy.allowStatic)) return;
        // D-294: never approach an identified avoided contact. Unidentified
        // dots stay approachable (advance_unknown_radar owns that): approach
        // is the only way to identify them; the blind SHOT is what is refused.
        if(c.def && (c.def->GetCategory()&policy.avoidCategory)) return;
        const float dist=pos.SqDistance2D(c.pos);
        if(dist<nearest && (!c.def || (c.def->GetCategory()&def->GetTargetCategory()))) { nearest=dist; objective=i; }
    };
    // D-295: with no legal shot, prefer the nearest visible contact an allied
    // screen is already fighting (precedence: shot > danger/closing > assist >
    // nearest objective). O(K) over contacts within assistRadius, reusing
    // assistNearby; Engaged is memoised per contact per frame and evaluated
    // only for a candidate nearer than the current best.
    bool assisting=false; int assistAlly=-1;
    if(best<0 && policy.assistRadius>0.f && !closing) {
        performance::Scope assistPhase(ai,performance::RANGED_ASSIST);
        world.Nearby(pos,policy.assistRadius,assistNearby);
        for(int i:assistNearby) {
            const auto& c=contacts[i];
            if(!c.def || !c.los || c.def->IsAbleToFly()) continue;
            if((c.mobile?!policy.allowMobile:!policy.allowStatic) || !(c.def->GetCategory()&def->GetTargetCategory())
                || (c.def->GetCategory()&policy.avoidCategory)) continue;
            // Target hysteresis: a moving fight re-ranks "nearest" every few
            // seconds; without it (8v8 20261014T015406Z) a Starlight changed
            // assist target 19-23 times in three minutes with destinations
            // jumping 500-2000 elmos. Keep the current target unless another
            // engaged contact is at least ~1.7x nearer (0.33 on squared distance).
            const float distance=pos.SqDistance2D(c.pos)*(c.id==assistTarget?.33f:1.f);
            if(distance>=nearest) continue;
            int ally=-1;
            if(!world.Engaged(i,policy.assistMargin,&ally)) continue;
            nearest=distance; objective=i; assistAlly=ally;
        }
        assisting=objective>=0;
    }
    if(!assisting) {
        assistTarget=-1;
        if(best>=0) consider(best);
        else for(int i:choices) consider(i);
    }
    // Nearby aircraft or incompatible contacts must not hide every distant
    // reachable ground objective. The shared shortlist is bounded to 16.
    if(objective<0) for(int i:world.Objectives()) {
        const auto& c=contacts[i];
        if (policy.holdFireline && !c.los) continue;
        if(!c.def && !policy.advanceUnknownRadar) { ++unknownObjectives; continue; }
        if((c.mobile?!policy.allowMobile:!policy.allowStatic) || (c.def && !(c.def->GetCategory()&def->GetTargetCategory()))) continue;
        if(c.def && (c.def->GetCategory()&policy.avoidCategory)) continue; // D-294 (unknown dots approachable, see above)
        const float distance=pos.SqDistance2D(c.pos);
        if(distance<nearest) { nearest=distance; objective=i; }
    }
    if(report && unknownObjectives>0) ai->LOG("RANGED: unknown radar approach withheld unit=%d candidates=%d",id,unknownObjectives);
    if(objective<0) {
        if(report) ai->LOG("RANGED: no objective unit=%d",id);
        if (policy.holdFireline) Hold(unit,true); else Disperse(unit);
        return;
    }
    const auto& c=contacts[objective];
    if(!c.def && !policy.advanceUnknownRadar) {
        ai->LOG("[INVARIANT] INV-149 precision movement selected an unidentified radar objective");
        return;
    }
    const float spacing=policy.spacing;
    AIFloat3 back=pos-c.pos; back.Normalize2D();
    const float baseAngle=std::atan2(back.z,back.x);
    float chosenScore=std::numeric_limits<float>::max(); AIFloat3 chosen=pos; bool found=false;
    int terrainRejected=0,slotRejected=0,coverageRejected=0,fireRejected=0;
    for(const auto& w:caps.weapons) {
        if(c.def && !(w.category&c.def->GetCategory())) continue;
        const float range=world.Range(w,pos,c.pos)*policy.rangeFraction;
        for(int k=0;k<17;++k) {
            const int slot=(k+failures)%17;
            const int side=slot==0?0:((slot%2)?(slot+1)/2:-slot/2);
            const float angle=baseAngle+side*std::max(.12f,spacing/std::max(1.f,range));
            AIFloat3 point(c.pos.x+std::cos(angle)*range,0.f,c.pos.z+std::sin(angle)*range);
            CTerrainManager::CorrectPosition(point);
            point.y=ai->GetTerrainManager()->GetAreaData()->GetElevationAt(point.x,point.z);
            if(!ai->GetTerrainManager()->CanMoveToPos(unit->GetArea(),point)) { ++terrainRejected; continue; }
            if(!world.FreeSlot(id,point,spacing)) { ++slotRejected; continue; }
            if(!world.Safe(pos,point,policy.safetyMargin,true,policy.pressStatic)
                || world.DangerSign(point,policy.safetyMargin,policy.pressStatic)>0.f) { ++coverageRejected; continue; }
            // D-295: an assist standoff stays behind the allied screen.
            if(assisting && policy.assistScreen && !world.HasScreen(id,point,c.pos)) { ++coverageRejected; continue; }
            if(!world.Trajectory(w,point,c.pos)) { ++fireRejected; continue; }
            if(world.FriendlyLine(w,id,point,c.pos)) { ++fireRejected; continue; }
            // Forward-fire policy chooses safe advancing/lateral firing sites,
            // never a rearward range correction. O(1) within the existing
            // bounded site loop; independent of other ranged units' kiting.
            if (policy.holdFireline && ((point.x-pos.x)*(c.pos.x-pos.x)+(point.z-pos.z)*(c.pos.z-pos.z))<0.f) continue;
            const float move=pos.SqDistance2D(point);
            const float stable=destination.SqDistance2D(point)<policy.hysteresis*policy.hysteresis?.8f:1.f;
            const float screen=policy.preferScreen && !world.HasScreen(id,point,c.pos)?1.15f:1.f;
            const float score=move*stable*screen;
            if(failures>0 && move<4096.f) continue;
            if(score<chosenScore) { chosenScore=score; chosen=point; found=true; }
        }
    }
    if (!found && policy.stageWhenBlocked && c.def) {
        // D-216: a mid-range support hull must not wait at its spawn merely
        // because the observed static line outranges it. Stage on our side of
        // that line, outside every known weapon/death-blast disc. This does not
        // invent a safe firing solution or relax path/splash/retreat checks.
        // Bounded 3x9 sites, only after the normal 17-site search fails.
        const float radius = std::max(maxRange, CRangedWorld::HazardFor(c, policy.pressStatic) + policy.safetyMargin) + policy.spacing;
        for (int ring = 0; ring < 3; ++ring) for (int k = 0; k < 9; ++k) {
            const int side = k == 0 ? 0 : ((k % 2) ? (k + 1) / 2 : -k / 2);
            const float angle = baseAngle + side * .16f;
            const float band = radius + ring * policy.spacing;
            AIFloat3 point(c.pos.x + std::cos(angle) * band, 0.f, c.pos.z + std::sin(angle) * band);
            CTerrainManager::CorrectPosition(point);
            point.y = ai->GetTerrainManager()->GetAreaData()->GetElevationAt(point.x, point.z);
            // Advance, never replace an already closer position with rearward
            // staging. Slot reservations preserve spacing between the hulls.
            if (point.SqDistance2D(c.pos) >= pos.SqDistance2D(c.pos)
                || !world.FreeSlot(id, point, spacing) || world.DangerSign(point, policy.safetyMargin, policy.pressStatic) > 0.f
                || !world.Safe(pos, point, policy.safetyMargin, true, policy.pressStatic)
                || !ai->GetTerrainManager()->CanMoveToPos(unit->GetArea(), point)) continue;
            const float score = pos.SqDistance2D(point);
            if (score < chosenScore) { chosenScore = score; chosen = point; found = true; }
        }
        if (report && found) ai->LOG("RANGED: staging unit=%d outside target=%d coverage", id, c.id);
    }
    if(found && assisting) {
        // INV-205: the selected assist site is outside known static coverage
        // on its path and carries no danger sign. Same predicates as the
        // site loop; fires only on a regression. Two O(local) queries.
        if(!world.Safe(pos,chosen,policy.safetyMargin,true,policy.pressStatic) || world.DangerSign(chosen,policy.safetyMargin,policy.pressStatic)>0)
            ai->LOG("[INVARIANT] INV-205 ranged assist destination is covered unit=%d target=%d dest=%.0f,%.0f",id,c.id,chosen.x,chosen.z);
        if(c.id!=assistTarget) {
            assistTarget=c.id; assistInvariantLogged=false; assistIdleStreak=0;
            ai->LOG("RANGED: assist unit=%d target=%d ally=%d dest=%.0f,%.0f",id,c.id,assistAlly,chosen.x,chosen.z);
        }
    }
    // D-295 hysteresis: a moving assist follows a moving fight. Keep a live,
    // still-legal route (or a pending query) whose goal is within one spacing
    // of the new site instead of re-pathing every 8-frame decision.
    const bool keepAssist=found && assisting && destination.SqDistance2D(chosen)<spacing*spacing
        && (query || (moving && ai->GetUnitAPI()->GetCMDQueueSize(id)>0 && LegalPath(unit,path,true)));
    if(keepAssist) {
        world.SetSlot(id,destination,spacing,def->GetCostM());
    } else if(found) {
        world.SetSlot(id,chosen,spacing,def->GetCostM());
        if(Move(unit,chosen,true) && assisting) { assistCheckFrame=frame; assistCheckRejections=rejections; }
    } else if(!moving) world.SetSlot(id,pos,spacing,def->GetCostM());
    if(report) ai->LOG("RANGED: sites unit=%d target=%d known=%d found=%d terrain=%d slots=%d coverage=%d fire=%d dest=%.0f,%.0f moving=%d query=%d queryid=%d generation=%u",id,c.id,c.def!=nullptr,int(found),terrainRejected,slotRejected,coverageRejected,fireRejected,chosen.x,chosen.z,int(moving),query?int(query->GetState()):-1,query?query->GetId():-1,generation);
    if(pos.SqDistance2D(lastPos)>1024.f) { lastPos=pos; lastProgressFrame=frame; failures=0; }
    // A blocked shot/site causes a new safe-position search, never pursuit.
    if(frame-lastProgressFrame>300 && lastReload<frame && target>=0) {
        destination=AIFloat3(-1.f,0.f,-1.f); ++failures; lastProgressFrame=frame;
    }
}
}
