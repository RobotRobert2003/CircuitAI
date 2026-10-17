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
#include "CircuitAI.h"
#include "util/Utils.h"
#include "Log.h"
#include "Damage.h"
#include <cstdlib>
#include <limits>
#include <memory>

namespace circuit {
using springai::AIFloat3;
using commander::Point;
static Point P(const AIFloat3& p) { return {p.x,p.z}; }

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

bool CCommanderControl::Fire(CCircuitUnit* unit,State& s,const commander::Line& line,int frame) {
    const auto pos=unit->GetPos(frame); const float range=unit->GetDGunRange()-12;
    auto* def=unit->GetCircuitDef();
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
    if(options.t3Trade<=0) {
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
            if(!explosion.blastDamage.empty()) blast+=commander::BlastDamage(
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

// D-294: CCommanderControl::Intercept moved to CommanderT3.cpp (per-T3 engagement).
}
