#include "module/CommanderControl.h"
#include "module/BuilderManager.h"
#include "module/EconomyManager.h"
#include "module/MilitaryManager.h"
#include "task/builder/CommanderTask.h"
#include "task/fighter/RangedWorld.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyManager.h"
#include "unit/enemy/EnemyUnit.h"
#include "setup/SetupManager.h"
#include "spring/SpringCallback.h"
#include "spring/SpringUnit.h"
#include "spring/SpringMap.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include "Damage.h"
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <memory>

namespace circuit {
using springai::AIFloat3;
using commander::Point;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }
static AIFloat3 F(Point p,float y=0) { return {p.x,y,p.z}; }

const CCommanderControl::Definition& CCommanderControl::DefinitionFor(CCircuitDef* def) {
    auto [it,inserted]=definitions.try_emplace(def->GetId());
    if(inserted) {
        auto* ud=def->GetDef(); auto& d=it->second;
        d.radar=ud->GetRadarRadius(); d.jammer=ud->GetJammerRadius();
        d.seismic=ud->GetSeismicRadius(); d.decloak=ud->GetDecloakDistance(); d.stealth=ud->IsStealth();
        const auto& params=ud->GetCustomParams();
        const auto level=params.find("techlevel");
        d.t3=level!=params.end() && std::atoi(level->second.c_str())>=3 && def->IsMobile() && def->IsAttacker();
        d.tech=level!=params.end()?float(std::atof(level->second.c_str())):1.f;
        if(def->IsMobile() && def->IsAttacker()) {
            const std::unique_ptr<springai::WeaponDef> blast(ud->GetDeathExplosion());
            if(blast) {
                d.blastRadius=blast->GetAreaOfEffect(); d.blastEdge=blast->GetEdgeEffectiveness();
                const std::unique_ptr<springai::Damage> damage(blast->GetDamage());
                if(damage) d.blastDamage=damage->GetTypes();
            }
        }
    }
    return it->second;
}

bool CCommanderControl::CloakSafe(CCircuitUnit* unit,Point from,Point to,float seconds) {
    const auto& own=DefinitionFor(unit->GetCircuitDef());
    for(const auto& c:contacts) if(!c.friendly
        && commander::Separation(from,to,c.pos,c.velocity,seconds)<=own.decloak+options.detectionMargin+c.radius) return false;
    // Known sensor coverage includes previously scouted static radars beyond
    // the local combat radius. Refresh once/second per AI only during T3 work:
    // O(known enemies), retained value storage, no hidden-state callbacks.
    const int frame=ai->GetLastFrame();
    if(frame>=sensorFrame+30) {
        sensorFrame=frame; sensors.clear();
        for(const auto& [id,enemy]:ai->GetEnemyManager()->GetEnemyUnits()) {
            auto* def=enemy->GetCircuitDef();
            if(!def || enemy->IsDead() || enemy->IsNeutral() || enemy->IsFake()) continue;
            const auto& d=DefinitionFor(def);
            if(d.radar<=0 && d.seismic<=0) continue;
            const bool los=enemy->IsInLOS(), blip=!los && enemy->IsInRadar();
            if(los && !ai->GetUnitAPI()->IsActiveSensor(id)) continue;
            // A mobile radar lost to fog can have moved since last sighting.
            // Grow that uncertainty only for sensor_memory seconds: past it,
            // the position is unknown, as for a sensor never seen. Unbounded
            // growth let one long-lost enemy commander (BAR commanders carry
            // radar) cover the whole map and disable every T3 ambush (D-293).
            const float age=float(frame-enemy->GetLastSeen())/FRAMES_PER_SEC;
            if(def->IsMobile() && !los && !blip && age>options.sensorMemory) continue;
            const float uncertainty=los?def->GetSpeed():blip?def->GetSpeed()+64.f:
                def->GetSpeed()*std::max(1.f,age);
            sensors.push_back({P(enemy->GetPos()),d.radar>0?d.radar+uncertainty:0,
                d.seismic>0?d.seismic+uncertainty:0});
            static const bool sensorTrace=std::getenv("CIRCUIT_COMMANDER_TRACE")!=nullptr;
            if(sensorTrace) ai->LOG("[CommanderTrace] sensor id=%i def=%s radar=%.0f seismic=%.0f los=%i blip=%i",
                id,def->GetDef()->GetName(),d.radar,d.seismic,int(los),int(blip));
        }
    }
    static const bool trace=std::getenv("CIRCUIT_COMMANDER_TRACE")!=nullptr;
    bool radar=false;
    for(const auto& sensor:sensors) {
        const float separation=commander::Separation(from,to,sensor.pos,{},0);
        const bool seismic=sensor.seismic>0 && separation<=sensor.seismic+options.detectionMargin;
        const bool covered=sensor.radar>0 && separation<=sensor.radar+options.detectionMargin;
        if(trace && (seismic || covered) && frame%30<3)
            ai->LOG("[CommanderTrace] unit=%i sensor at %.0f,%.0f radar=%.0f seismic=%.0f separation=%.0f",
                unit->GetId(),sensor.pos.x,sensor.pos.z,sensor.radar,sensor.seismic,separation);
        if(seismic) return false;
        radar|=covered;
    }
    if(!radar || own.stealth) return true;
    // One live friendly jammer must cover the whole segment (convex disc),
    // including its predicted motion. Do not assume inactive/unfinished units
    // jam, or that cloak itself removes a radar return.
    for(const auto& c:contacts) if(c.friendly) {
        auto* def=ai->GetCircuitDefSafe(ai->GetCallback()->Unit_GetDefId(c.id));
        if(!def) continue;
        const float radius=DefinitionFor(def).jammer-options.detectionMargin;
        if(radius<=0 || !ai->GetUnitAPI()->IsActiveSensor(c.id)) continue;
        if(commander::Length(from-c.pos)<radius
            && commander::Length(to-(c.pos+c.velocity*seconds))<radius) return true;
    }
    return false;
}

bool CCommanderControl::Fire(CCircuitUnit* unit,State& s,const commander::Line& line,int frame,bool acceptT3Risk) {
    const auto pos=unit->GetPos(frame); const float range=unit->GetDGunRange()-12;
    auto* def=unit->GetCircuitDef();
    if(acceptT3Risk) {
        const auto target=std::find_if(contacts.begin(),contacts.end(),[&](const commander::Contact& c) {
            return c.id==line.target && c.t3 && c.targetable && !c.friendly && !c.blocker && !c.reserved;
        });
        auto* owner=dynamic_cast<CCommanderTask*>(unit->GetTask());
        if(options.t3ImmediateShot<=0 || target==contacts.end() || !line.requiredHit || line.blocked
            || !owner || owner->GetAssignees().size()!=1 || !owner->GetAssignees().count(unit)) {
            ai->LOG("[INVARIANT] INV-233 invalid immediate T3 shot unit=%i target=%i",unit->GetId(),line.target);
            return false;
        }
    }
    if(s.afusEngagement && protectedAfus<0) {
        ai->LOG("[INVARIANT] INV-225 commander AFUS shot outside observed protection scope unit=%i",unit->GetId());
        return false;
    }
    // INV-216: BAR D-guns have firesubmersed=false; a submerged order would
    // only waste the lease. Every caller filters water; this is the backstop.
    if(pos.y<0.f) {
        ai->LOG("[INVARIANT] INV-216 commander D-gun ordered while submerged unit=%i y=%.0f",unit->GetId(),pos.y);
        return false;
    }
    const float speed=std::max(1.f,def->GetDGunDef()->GetDef()->GetProjectileSpeed()*30.f);
    const float width=std::min(24.f,std::max(4.f,def->GetDGunDef()->GetAoe()*.25f));
    // All three firing paths share this final admission check: an ordinary
    // line shot or fallback shot must not bypass T3 death-blast protection.
    // O(local contacts), only when issuing a shot; definitions are AI-owned
    // immutable caches. Predict the same intersections used by shot claims.
    // A priority D-gun (PriorityDGun) is ordered ahead of survival: the owner
    // trades the commander's risk for the shot at a Juggernaut-class unit.
    if(options.t3Trade<=0 && !acceptT3Risk) {
        const auto& cap=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(def);
        const int armor=std::max(0,def->GetDef()->GetArmorType());
        float blast=0; bool t3=false;
        for(const auto& c:contacts) {
            if(c.friendly || c.blocker || !c.targetable || (!c.t3 && !(s.afusEngagement && c.combatTier>0))) continue;
            const float along=commander::Dot(c.pos-P(pos),line.direction);
            const Point hit=c.pos+c.velocity*(std::max(0.f,along)/speed);
            if(commander::Dot(hit-P(pos),line.direction)<0
                || !commander::Intersects(hit-P(pos),line.direction,range,c.radius+width)) continue;
            auto* enemy=ai->GetEnemyManager()->GetEnemyUnit(c.id);
            auto* targetDef=enemy?enemy->GetCircuitDef():nullptr;
            if(!targetDef) continue;
            const auto& explosion=DefinitionFor(targetDef);
            if(!explosion.t3 && !s.afusEngagement) continue;
            t3=true;
            // Only a killing hit sets off the death blast.
            if(!explosion.blastDamage.empty() && c.health<=c.damage*1.15f) blast+=commander::BlastDamage(
                explosion.blastDamage[std::min(size_t(armor),explosion.blastDamage.size()-1)],
                explosion.blastRadius,explosion.blastEdge,commander::Length(hit-P(pos))-cap.radius);
        }
        const float floor=s.t3Target>=0?s.t3MinHealth:options.t3Health;
        // A funded, undetected cloak hides the aiming lease; firing reveals
        // the commander and starts its lateral escape. Visible aiming gets
        // the full additional second. Keep flight plus a post-impact tail.
        const bool concealed=t3 && unit->GetUnit()->IsCloaked() && CloakSafe(unit,P(pos),P(pos),1.f);
        const float exposedSeconds=range/speed+.3f+(concealed?0.f:1.f);
        if(t3 && !commander::Survivable(unit->GetUnit()->GetHealth(),unit->GetUnit()->GetMaxHealth(),
            Exposure(P(pos),P(pos),exposedSeconds,pos.y,concealed,
                concealed && s.t3Target>=0?options.t3CloakedVolleyRisk:1.f)+blast,floor)) {
            s.retry=frame+15; Transition(unit,s,Mode::ESCAPE,frame);
            ai->LOG("[Commander] unit=%i blocked_shot=t3_survival target=%i blast=%.0f",unit->GetId(),line.target,blast);
            return false;
        }
    }
    AIFloat3 aim(pos.x+line.direction.x*(range-4),0,pos.z+line.direction.z*(range-4));
    aim.y=std::max(0.f,ai->GetMap()->GetElevationAt(aim.x,aim.z));
    s.target=line.target; s.pending=frame; s.leaseUntil=frame+30;
    auto& claims=ai->GetAllyTeam()->GetCommanderShots(); claims.Release(ai->GetTeamId(),unit->GetId());
    for(const auto& c:contacts) {
        if(c.friendly || c.blocker || !c.targetable) continue;
        const float along=commander::Dot(c.pos-P(pos),line.direction);
        const Point d=c.pos+c.velocity*(std::max(0.f,along)/speed)-P(pos);
        if(commander::Dot(d,line.direction)>=0 && commander::Intersects(d,line.direction,range,c.radius+width))
            claims.Reserve({ai->GetTeamId(),unit->GetId(),s.generation,c.id,frame+30,c.damage});
    }
    s.route.clear(); Transition(unit,s,Mode::PENDING,frame);
    TRY_UNIT(ai,unit,unit->GetUnit()->DGunPosition(aim,0,frame+30);)
    ai->LOG("[Commander] unit=%i shot_pending target=%i kills=%i value=%.1f energy=%.1f",unit->GetId(),line.target,line.kills,line.value,ai->GetEconomyManager()->GetEnergyCur());
    return true;
}

bool CCommanderControl::PriorityDGun(CCircuitUnit* unit,State& s,int frame) {
    if(!priorityResolved) {
        priorityResolved=true;
        // Juggernaut, Titan, Behemoth, Sol Invictus (and its archaic version).
        for(const char* name:{"corkorg","armbanth","corjugg","legeheatraymech","legeheatraymech_old"})
            if(auto* d=ai->GetCircuitDef(name)) priorityDefs.insert(d->GetId());
    }
    // Our own pending override shot: WeaponFired clears pending on dispatch.
    if(s.priorityShot>=0) {
        if(s.pending<0 || unit->GetDGunReloadFrame()>frame) {
            if(s.pending>=0) { s.fired=frame; s.pending=-1; }
            ai->LOG("[CommanderPriority] unit=%i target=%i action=fired aim=%.1fs frame=%i",
                unit->GetId(),s.priorityTarget,float(frame-s.priorityShot)/FRAMES_PER_SEC,frame);
            s.priorityShot=-1;
        } else if(frame-s.pending>30) {
            ai->LOG("[CommanderPriority] unit=%i target=%i action=timeout frame=%i",unit->GetId(),s.priorityTarget,frame);
            s.pending=-1; s.leaseUntil=0; s.priorityShot=-1;
            ai->GetAllyTeam()->GetCommanderShots().Release(ai->GetTeamId(),unit->GetId());
        } else return true;
    }
    if(options.priorityDGun<=0 || priorityDefs.empty()) return false;
    const AIFloat3 pos=unit->GetPos(frame);
    if(pos.y<0.f) return false; // BAR D-guns do not fire submerged
    auto* def=unit->GetCircuitDef();
    const float range=unit->GetDGunRange()-12;
    const float speed=std::max(1.f,def->GetDGunDef()->GetDef()->GetProjectileSpeed()*30.f);
    const float width=std::min(24.f,std::max(4.f,def->GetDGunDef()->GetAoe()*.25f));
    // Nearest listed unit in reach: the shot's lane must pass through its body
    // (half its radius past the D-gun's end), on the surface, and no friendly
    // commander in the lane. Other friendlies in the lane are accepted losses.
    // Out of reach but within t3_distance, the nearest one is closed on
    // directly instead (no hidden-station, funding or screen declines).
    const commander::Contact* target=nullptr; commander::Line best; float nearest=1e9f;
    const commander::Contact* chase=nullptr; float chaseDistance=std::min(options.scan,options.t3Distance);
    for(const auto& c:contacts) {
        if(c.friendly || c.blocker || !c.targetable) continue;
        auto* enemy=ai->GetEnemyInfo(c.id);
        if(!enemy || !enemy->GetCircuitDef() || !priorityDefs.count(enemy->GetCircuitDef()->GetId())) continue;
        const float distance=commander::Length(c.pos-P(pos));
        if(distance>range+c.radius*.5f) {
            if(distance<chaseDistance) { chaseDistance=distance; chase=&c; }
            continue;
        }
        if(distance>=nearest) continue;
        if(std::abs(c.height-std::max(0.f,pos.y))>range*.5f) continue;
        const Point lead=c.pos+c.velocity*(distance/speed);
        commander::Line line; line.direction=commander::Normal(lead-P(pos));
        if(commander::Length(line.direction)<.5f) continue;
        bool commanderInLane=false;
        for(const auto& f:contacts) {
            if(!f.friendly || !f.blocker) continue;
            const float along=commander::Dot(f.pos-P(pos),line.direction);
            const Point d=f.pos+f.velocity*(std::max(0.f,along)/speed)-P(pos);
            if(commander::Dot(d,line.direction)>=0 && commander::Intersects(d,line.direction,range,f.radius+width+options.friendlyMargin)) {
                commanderInLane=true; break;
            }
        }
        if(commanderInLane) continue;
        line.target=c.id; line.value=c.cost; line.requiredHit=true;
        target=&c; best=line; nearest=distance;
    }
    if(!target) {
        s.priorityInReach=-1;
        return chase!=nullptr && PriorityApproach(unit,s,*chase,chaseDistance,frame);
    }
    if(s.priorityTarget!=target->id || s.priorityInReach<0) {
        s.priorityTarget=target->id; s.priorityInReach=frame;
        ai->LOG("[CommanderPriority] unit=%i target=%i def=%s action=in_reach distance=%.0f range=%.0f frame=%i",
            unit->GetId(),target->id,ai->GetEnemyInfo(target->id)->GetCircuitDef()->GetDef()->GetName(),nearest,range,frame);
    }
    // Actual bank only: the shot outranks every other commander's reserve.
    const float bank=ai->GetEconomyManager()->GetEnergyCur();
    if(!unit->IsDGunReady(frame,bank)) {
        if(frame%30<3) ai->LOG("[CommanderPriority] unit=%i target=%i action=wait reason=%s energy=%.0f frame=%i",
            unit->GetId(),target->id,unit->GetDGunReloadFrame()>frame?"reload":"energy",bank,frame);
        return false;
    }
    auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask());
    if(!task) {
        auto* current=unit->GetTask();
        task=ai->GetBuilderManager()->EnqueueCommander(current);
        ai->GetBuilderManager()->AssignTask(unit,task);
        if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task); return false; }
        s.started=frame; s.cloak=WantsCloak(unit); s.failed=0; ++operation;
        unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
        TRY_UNIT(ai,unit,unit->CmdStop();)
    }
    if(task->GetAssignees().size()!=1 || !task->GetAssignees().count(unit) || unit->GetDGunAct()) {
        ai->LOG("[INVARIANT] INV-214 commander priority shot has competing owner unit=%i",unit->GetId());
        task->Resume(unit); return true;
    }
    if(!Fire(unit,s,best,frame,true)) return false;
    s.priorityShot=frame;
    ai->LOG("[CommanderPriority] unit=%i target=%i action=fire distance=%.0f in_reach=%.1fs energy=%.0f frame=%i",
        unit->GetId(),target->id,nearest,float(frame-s.priorityInReach)/FRAMES_PER_SEC,bank,frame);
    return true;
}

bool CCommanderControl::PriorityApproach(CCircuitUnit* unit,State& s,const commander::Contact& target,float distance,int frame) {
    auto* def=unit->GetCircuitDef();
    const auto& cap=ai->GetMilitaryManager()->GetRangedWorld()->CapabilitiesFor(def);
    const float shot=def->GetDGunDef()->GetCostE(),bank=ai->GetEconomyManager()->GetEnergyCur();
    if(bank<shot) return false; // nothing to shoot with on arrival: ordinary withdrawal
    const AIFloat3 pos=unit->GetPos(frame);
    const float range=unit->GetDGunRange()-12;
    const float speed=std::max(1.f,cap.speed);
    // Meet it where it will be: lead by our travel time, stand range-40 off
    // its centre on our side (the T3 plan's own station distance).
    const Point lead=target.pos+target.velocity*std::min(3.f,distance/speed);
    AIFloat3 goal=F(lead+commander::Normal(P(pos)-lead)*std::max(0.f,range-40.f));
    goal.y=ai->GetMap()->GetElevationAt(goal.x,goal.z);
    if(goal.y<0 || !OnMap(goal) || !ai->GetTerrainManager()->CanReachAt(unit,goal,64)) {
        goal=F(target.pos); goal.y=ai->GetMap()->GetElevationAt(goal.x,goal.z);
        if(goal.y<0 || !OnMap(goal) || !ai->GetTerrainManager()->CanReachAt(unit,goal,64)) return false;
    }
    auto* task=dynamic_cast<CCommanderTask*>(unit->GetTask());
    if(!task) {
        auto* current=unit->GetTask();
        task=ai->GetBuilderManager()->EnqueueCommander(current);
        ai->GetBuilderManager()->AssignTask(unit,task);
        if(unit->GetTask()!=task) { ai->GetBuilderManager()->AbortTask(task); return false; }
        s.started=frame; s.cloak=WantsCloak(unit); s.failed=0; ++operation;
        unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
        TRY_UNIT(ai,unit,unit->CmdStop();)
    }
    if(task->GetAssignees().size()!=1 || !task->GetAssignees().count(unit) || unit->GetDGunAct()) {
        ai->LOG("[INVARIANT] INV-214 commander priority approach has competing owner unit=%i",unit->GetId());
        task->Resume(unit); return true;
    }
    // Cloak the walk in when the bank also covers the shot; otherwise walk in
    // visible. Either way the commander keeps closing.
    const bool cloak=cap.cloak && bank>=shot+cap.cloakMoving*(distance/speed+1.f);
    Conceal(unit,s,cloak); Transition(unit,s,Mode::APPROACH,frame);
    Move(unit,s,goal,frame);
    if(frame%30<3) ai->LOG("[CommanderPriority] unit=%i target=%i action=approach distance=%.0f goal=%.0f,%.0f cloak=%i frame=%i",
        unit->GetId(),target.id,distance,goal.x,goal.z,int(cloak),frame);
    return true;
}

// D-294: CCommanderControl::Intercept moved to CommanderT3.cpp (per-T3 engagement).
}
