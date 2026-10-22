#include "task/fighter/RangedWorld.h"
#include "CircuitAI.h"
#include "unit/CircuitUnit.h"
#include "unit/enemy/EnemyManager.h"
#include "unit/enemy/EnemyUnit.h"
#include "spring/SpringUnit.h"
#include "terrain/TerrainManager.h"
#include "terrain/HeightMapGeometry.h"
#include "module/MilitaryManager.h"
#include "setup/SetupManager.h"
#include "util/Utils.h"
#include "Log.h"
#include <algorithm>
#include <limits>
#include <cstdlib>

namespace circuit {
using springai::AIFloat3;
static ranged::Point P(const AIFloat3& p) { return {p.x,p.z}; }
static float Projection(const AIFloat3& p,const AIFloat3& axis) { return p.x*axis.x+p.z*axis.z; }

void CRangedWorld::JoinCohort(CCircuitUnit* unit)
{
    const int id=unit->GetId();
    const auto* def=unit->GetCircuitDef(); const auto& policy=def->GetRangedPolicy();
    const auto pos=unit->GetPos(circuit->GetLastFrame());
    int chosen=-1; float nearest=policy.cohortRadius*policy.cohortRadius;
    const auto consider=[&](int other) {
        auto m=membership.find(other); if(m==membership.end()) return;
        auto& g=cohorts.at(m->second);
        if(g.members.size()>=size_t(policy.cohortSize)) return;
        auto* ally=circuit->GetTeamUnit(other);
        if(!ally || ally->GetCircuitDef()!=def || ally->GetArea()!=unit->GetArea()) return;
        if(policy.engagementSeconds>0.f) {
            auto* anchor=circuit->GetTeamUnit(g.members.front());
            if(!anchor || !cohort::Admit(P(pos),P(anchor->GetPos(circuit->GetLastFrame())),
                policy.cohortRadius*.5f)) return;
        }
        const float d=pos.SqDistance2D(ally->GetPos(circuit->GetLastFrame()));
        if(d<nearest || (d==nearest && m->second<chosen)) { nearest=d; chosen=m->second; }
    };
    // Formation membership follows actual nearby bodies, not their reserved
    // destination slots. A travelling cohort may reserve a point far ahead;
    // using that index strands newly produced screens in singleton groups.
    // Keep the legacy lookup for units that have not opted into formations.
    if(policy.formationPosition!=RangedPolicy::FormationPosition::NONE) {
        EnsureAllies();
        allies.Query(P(pos),policy.cohortRadius,[&](int index) { consider(friends[index].id); });
    } else
        formations.Query(P(pos),policy.cohortRadius,consider);
    if(chosen<0) chosen=nextCohort++;
    auto& group=cohorts[chosen]; group.members.push_back(id);
    InvalidateCohortPlans(group);
    membership[id]=chosen;
}

const CRangedWorld::CohortPlan& CRangedWorld::PlanIndependentCohort(CCircuitUnit* unit)
{
    const int now=circuit->GetLastFrame(), id=unit->GetId();
    const auto* def=unit->GetCircuitDef(); const auto& policy=def->GetRangedPolicy();
    if(!membership.count(id)) JoinCohort(unit);
    int key=membership.at(id);
    // Merge local partial cohorts, never scan all squads. Sample only on the
    // leader's staggered two-second window; membership/slots are callback-owned.
    // Lower cohort ID wins, so merges cannot oscillate or invalidate another
    // currently executing task. Each member is still ordered only by its task.
    auto& current=cohorts.at(key);
    // Do not use the shared plan's last frame as this clock: a follower can
    // refresh it immediately before the leader and starve merging forever.
    // Full cohorts cannot accept a merge, so avoid their local query entirely.
    if(current.formationPartner<0 && current.members.front()==id && current.members.size()<size_t(policy.cohortSize) && now>=current.nextMerge) {
        current.nextMerge=now+60;
        int merge=-1;
        const auto pos=unit->GetPos(now);
        formations.Query(P(pos),policy.cohortRadius,[&](int other) {
            auto m=membership.find(other);
            if(m==membership.end() || m->second>=key) return;
            auto& g=cohorts.at(m->second); auto* ally=circuit->GetTeamUnit(other);
            if(g.formationPartner>=0 || !ally || ally->GetCircuitDef()!=def || ally->GetArea()!=unit->GetArea()
                || current.members.size()+g.members.size()>size_t(policy.cohortSize)
                || ally->GetPos(now).SqDistance2D(pos)>policy.cohortRadius*policy.cohortRadius) return;
            if(policy.engagementSeconds>0.f) {
                if(current.target>=0 && g.target>=0 && current.target!=g.target) return;
                auto* anchor=circuit->GetTeamUnit(g.members.front());
                if(!anchor) return;
                // All recruits must fit the existing core, not just the last
                // unit of a long chain. K is bounded by the configured size.
                for(int recruit:current.members) {
                    auto* u=circuit->GetTeamUnit(recruit);
                    if(!u || !cohort::Admit(P(u->GetPos(now)),P(anchor->GetPos(now)),policy.cohortRadius*.5f)) return;
                }
            }
            if(merge<0 || m->second<merge) merge=m->second;
        });
        if(merge>=0) {
            auto& into=cohorts.at(merge);
            for(int member:current.members) { into.members.push_back(member); membership[member]=merge; }
            into.frame=-1; cohorts.erase(key); key=merge;
            circuit->LOG("COHORT: merged group=%d members=%u",key,unsigned(into.members.size()));
        }
    }
    auto& g=cohorts.at(key);
    if(g.frame==now) return g;
    g.frame=now;
    // Cohort bounds make the friendly pass O(K), K <= configured 12; no engine
    // inventory callback here. Enemy work is one local bucket query plus the
    // existing 16-objective shortlist per group, not per shooter.
    g.center=AIFloat3(); float value=0.f; unsigned core=0;
    auto* anchor=circuit->GetTeamUnit(g.members.front());
    const auto anchorPos=anchor?anchor->GetPos(now):unit->GetPos(now);
    for(int member:g.members) {
        auto* u=circuit->GetTeamUnit(member);
        if(!u || u->IsDead()) continue; // lifecycle Leave prunes the registry
        if(policy.engagementSeconds<=0.f || cohort::Admit(P(u->GetPos(now)),P(anchorPos),policy.cohortRadius*.5f)) {
            g.center+=u->GetPos(now); ++core;
        }
        if(policy.engagementSeconds<=0.f) value+=cohort::HealthValue(def->GetCostM(),u->GetUnit()->GetHealth(),def->GetHealth());
    }
    g.center*=1.f/float(std::max(1u,core));
    auto& nearby=g.candidates; Nearby(g.center,1400.f,nearby);
    // A damaged allied vanguard is a useful direction of combat, not another
    // unit inventory scan per enemy. The local spatial pass is once per cohort
    // plan and observes only legal friendly state. Assessment below still has
    // to admit the battle; an ally being hit is not permission to charge DGuns.
    AIFloat3 alliedFront=g.center; int engagedAllies=0;
    if(policy.supportAllies) {
        EnsureAllies();
        AIFloat3 sum;
        allies.Query(P(g.center),policy.cohortRadius,[&](int i) {
            const auto& f=friends[i];
            if(!f.def || !f.def->IsMobile() || !f.def->IsAttacker() || membership.count(f.id)) return;
            auto* ally=circuit->GetTeamUnit(f.id);
            if(!ally || ally->GetDamagedFrame()<now-3*FRAMES_PER_SEC) return;
            sum+=f.pos; ++engagedAllies;
        });
        if(engagedAllies) alliedFront=sum/float(engagedAllies);
    }
    int objective=-1; float score=std::numeric_limits<float>::max();
    const auto consider=[&](int index) {
        const auto& c=contacts[index];
        if(!c.def || c.def->IsAbleToFly() || c.pos.y< -20.f || !(c.def->GetCategory()&def->GetTargetCategory())) return;
        if(c.mobile?!policy.allowMobile:!policy.allowStatic) return;
        float distance=g.center.SqDistance2D(c.pos);
        if(engagedAllies) distance=.4f*distance+.6f*alliedFront.SqDistance2D(c.pos);
        if(c.id==g.target) distance/=policy.targetHysteresis;
        if(policy.engagementSeconds>0.f)
            distance/=Progress(c.id,policy.repairedTargetPenalty);
        if(distance<score) { score=distance; objective=index; }
    };
    for(int i:nearby) consider(i);
    if(objective<0) for(int i:objectives) consider(i);
    if(objective<0) {
        const bool lostContact=g.target>=0;
        g.target=-1;
        if(policy.engagementSeconds>0.f && g.protectedTarget>=0) {
            auto* memory=circuit->GetEnemyManager()->GetEnemyUnit(g.protectedTarget);
            if(memory && !memory->IsHidden() && !memory->IsDead() && !memory->IsDying()
                && memory->GetPos().SqDistance2D(g.center)<1400.f*1400.f) {
                // A lost observation of a commander/reclaimer is not cleared
                // ground. Keep the safe line until legal reconnaissance
                // invalidates memory or supplies another usable objective.
                g.mode=cohort::Mode::HOLD; g.focus=g.center; g.radius=0.f;
                g.assault.clear(); g.committed=false; g.reason=cohort::Reason::UNKNOWN;
                return g;
            }
            g.protectedTarget=-1;
        }
        // Check the last observed objective before holding the ground won.
        // Freezing at weapon range loses contacts at the edge of LOS; walking
        // to that already-known position reacquires them without reading fog.
        // The opening uses the role's lane without claiming a scout lease.
        const auto oldFocus=g.focus;
        if(policy.engagementSeconds>0.f && (g.objectiveFrame<0
            || (g.center.SqDistance2D(g.focus)<16384.f && now-g.objectiveFrame>=30))) {
            g.strategic=circuit->GetMilitaryManager()->GroundObjective(unit,g.focus);
            g.focus=g.strategic; g.objectiveFrame=now;
        }
        if(g.focus.SqLength2D()<1.f)
            g.focus=circuit->GetSetupManager()->GetLanePos();
        g.mode=g.center.SqDistance2D(g.focus)<16384.f?cohort::Mode::HOLD:cohort::Mode::ADVANCE;
        g.radius=0.f;
        g.assault.clear(); g.committed=false; g.reason=cohort::Reason::TRAVEL;
        // Keep formation orientation after arrival. Recomputing a direction
        // from its near-zero centroid error rotates every member's slot and
        // creates endless orders even though the battle has finished.
        if(lostContact || oldFocus!=g.focus || g.back.SqLength2D()<.5f) {
            g.back=g.center-g.focus; g.back.Normalize2D();
            if(g.back.SqLength2D()<.5f) g.back=AIFloat3(1,0,0);
        }
        return g;
    }
    const auto& enemy=contacts[objective];
    if(policy.engagementSeconds>0.f && (enemy.def->IsEnemyRoleAny(CCircuitDef::COMM)
        || enemy.def->IsAbleToReclaim())) g.protectedTarget=enemy.id;
    // Retain formation orientation across small target motion, but a pursuer
    // crossing the core must not leave its firing arc on the enemy's far side.
    const bool crossed=policy.engagementSeconds>0.f && Projection(g.center-enemy.pos,g.back)<0.f;
    if(g.target!=enemy.id || g.back.SqLength2D()<.5f || crossed) {
        g.back=g.center-enemy.pos; g.back.Normalize2D();
        if(g.back.SqLength2D()<.5f) g.back=AIFloat3(1,0,0);
    }
    g.target=enemy.id; g.focus=enemy.pos;
    const auto& capabilities=CapabilitiesFor(unit->GetCircuitDef());
    float range=def->GetMaxRange(CCircuitDef::RangeType::LAND);
    if(!capabilities.weapons.empty()) range=Range(capabilities.weapons.front(),g.center,enemy.pos);
    // A sustained campaign still selects fresh legal objectives here, but its
    // fixed-loss contract supersedes the ordinary exposure estimator.
    if(policy.sustainedRush && rushes.Active(id)) return g;
    if(policy.engagementSeconds>0.f) { AssessCohort(unit,g,enemy,range); return g; }
    const float firing=range*policy.rangeFraction;
    float hostileValue=0.f, danger=0.f; bool outranged=false;
    for(int i:nearby) {
        const auto& c=contacts[i];
        if(!c.def || !c.armed || c.def->IsAbleToFly() || c.pos.y< -20.f) continue;
        if(c.pos.SqDistance2D(enemy.pos)<600.f*600.f)
            hostileValue+=cohort::HealthValue(c.cost,c.health,c.def->GetHealth());
        const float reach=c.hazardRadius+policy.safetyMargin;
        if(c.id==enemy.id && c.groundRange>range) outranged=true;
        if(!c.mobile) {
            // Static coverage does not disappear when we step just outside
            // it. Intersect its circle with our approach axis; the old local
            // proximity switch alternated ADVANCE/WITHDRAW at that boundary,
            // issuing endless moves against the same unmoving turret bait.
            const AIFloat3 relative=c.pos-enemy.pos;
            const float along=Projection(relative,g.back);
            const float lateral=std::max(0.f,relative.SqLength2D()-along*along);
            if(lateral<reach*reach) {
                const float edge=along+std::sqrt(reach*reach-lateral);
                danger=std::max(danger,edge);
                if(edge>firing && c.groundRange>range) outranged=true;
            }
        } else if(g.center.SqDistance2D(c.pos)<(reach+80.f)*(reach+80.f)) {
            const float projected=Projection(c.pos-enemy.pos,g.back)+reach;
            danger=std::max(danger,projected);
            if(projected>firing && c.groundRange>range) outranged=true;
        }
    }
    unsigned ready=0;
    for(int member:g.members) {
        auto* u=circuit->GetTeamUnit(member);
        if(u && u->GetPos(now).SqDistance2D(enemy.pos)<std::pow(range+std::min(256.f,def->GetSpeed()*policy.catchSeconds),2.f)) ++ready;
    }
    // Distant reinforcements are not fighting strength. A cohort must actually
    // arrive before its leader is allowed to cross a longer-ranged weapon.
    AIFloat3 pursuit=enemy.pos-g.center; pursuit.Normalize2D();
    const float fleeingSpeed=std::max(0.f,Projection(enemy.velocity,pursuit));
    // A motionless artillery unit is catchable even if its definition could
    // outrun us. Re-evaluate observed escape speed every decision; do not keep
    // chasing when it starts kiting. Unknown/radar-only motion cannot admit it.
    const bool rush=ready*4>=g.members.size()*3 && enemy.los && enemy.mobile && enemy.armed && !enemy.def->IsEnemyRoleAny(CCircuitDef::COMM)
        && cohort::CanRush(range,enemy.groundRange,def->GetSpeed(),fleeingSpeed,
                          value,hostileValue,policy.rushRatio,policy.catchSeconds,
                          std::sqrt(g.center.SqDistance2D(enemy.pos)));
    g.mode=rush?cohort::Mode::RUSH:cohort::Mode::ADVANCE;
    g.radius=firing;
    if(!enemy.mobile && enemy.armed)
        g.radius=std::max(g.radius,enemy.hazardRadius+policy.safetyMargin+policy.spacing);
    if(!rush && (danger>firing || outranged)) {
        g.radius=std::max(firing,danger+policy.hysteresis);
        if(enemy.armed) g.radius=std::max(g.radius,enemy.hazardRadius+policy.safetyMargin+policy.hysteresis);
        g.mode=outranged?cohort::Mode::WITHDRAW:cohort::Mode::KITE;
    }
    float rear=0.f,front=std::numeric_limits<float>::max();
    for(int member:g.members) {
        auto* u=circuit->GetTeamUnit(member); if(!u) continue;
        const float depth=Projection(u->GetPos(now)-enemy.pos,g.back);
        rear=std::max(rear,depth); front=std::min(front,depth);
    }
    if(g.members.size()>1 && rear-front>policy.spacing*2.f && front>enemy.hazardRadius+policy.safetyMargin
        && now>=g.nextRegroup && g.regroupUntil<=now) {
        g.regroupUntil=now+int(policy.regroupSeconds*30.f);
        g.nextRegroup=g.regroupUntil+int(policy.regroupSeconds*30.f);
    }
    if(now<g.regroupUntil && rear-front>policy.spacing) {
        // Wait on our side, never pull rear members into enemy coverage while
        // the vanguard is waiting. A real escape overrides this bounded wait.
        g.radius=std::max(g.radius,rear-policy.spacing);
        if(g.mode!=cohort::Mode::WITHDRAW && g.mode!=cohort::Mode::KITE) g.mode=cohort::Mode::REGROUP;
    } else if(rear-front<=policy.spacing) g.regroupUntil=now;
    return g;
}

void CRangedWorld::ApplyRush(CCircuitUnit* unit, CohortPlan& g)
{
    const auto& p=unit->GetCircuitDef()->GetRangedPolicy();
    if(!p.sustainedRush) return;
    const int now=circuit->GetLastFrame(), id=unit->GetId();
    // Campaign liveness is checked even within an already planned frame:
    // destruction and task handover can occur between two shooters.
    int key=rushes.Find(id);
    if(key>=0 && (!rushes.Active(id) || g.target<0)) {
        const auto* c=rushes.Get(key);
        circuit->LOG("RUSH: end campaign=%d initial=%u remaining=%u reason=%s",key,
            c->initial,c->remaining,g.target<0?"clear":"losses");
        rushes.Finish(key,now); key=-1;
    }
    g.sustainedRush=false; g.rushFallback=rushes.Cooldown(id)>now;
    if(key<0 && !g.rushFallback && g.rushFrame!=now && g.target>=0
        && g.center.SqDistance2D(g.focus)<std::pow(p.sustainedRushRadius,2.f)) {
        g.rushFrame=now;
        EnsureAllies(); rushCandidates.clear();
        float own=0.f, hostile=0.f; unsigned fronts=0; bool present=false;
        int join=-1; float nearest=p.sustainedRushRadius*p.sustainedRushRadius;
        // Reuse the legal snapshot: O(B + F_local log N + E_local), for B
        // visited buckets and N owned units (GetTeamUnit is a map lookup).
        // Once/cohort/frame; committed lookup is expected O(1). No census.
        allies.Query(P(g.center),p.sustainedRushRadius,[&](int index) {
            const auto& f=friends[index];
            if(!f.def || f.pos.SqDistance2D(g.center)>p.sustainedRushRadius*p.sustainedRushRadius
                || membership.find(f.id)==membership.end()
                || rushes.Cooldown(f.id)>now) return;
            const auto& other=f.def->GetRangedPolicy();
            auto* live=circuit->GetTeamUnit(f.id);
            if(!other.sustainedRush || other.formationFamily!=p.formationFamily
                || !live || live->IsDead() || live->GetArea()!=unit->GetArea()) return;
            const int active=rushes.Find(f.id);
            if(active>=0) {
                const float distance=f.pos.SqDistance2D(g.center);
                if(rushes.Active(f.id) && (distance<nearest || (distance==nearest && (join<0 || active<join)))) {
                    nearest=distance; join=active;
                }
                return;
            }
            const bool front=other.formationPosition==RangedPolicy::FormationPosition::FRONT;
            rushCandidates.push_back({f.id,front});
            present=present || f.id==id;
            fronts+=front; own+=f.def->GetCostM();
        });
        if(join>=0) {
            rushes.Reinforce(join,rushCandidates); key=rushes.Find(id);
        } else if(present && float(fronts)>=p.sustainedRushMinFront
            && p.formationPosition==RangedPolicy::FormationPosition::FRONT) {
            const float extent=p.sustainedRushRadius+largestCohortHazard;
            bool unknown=false;
            enemies.Query(P(g.center),extent,[&](int index) {
                const auto& c=contacts[index];
                if(!c.def && c.pos.SqDistance2D(g.center)<=p.sustainedRushRadius*p.sustainedRushRadius) unknown=true;
                if(c.def && !c.def->IsAbleToFly() && c.pos.y>=-20.f
                    && c.pos.SqDistance2D(g.center)<=std::pow(p.sustainedRushRadius+c.hazardRadius,2.f))
                    hostile+=c.cost;
            });
            const float aggression=circuit->GetMilitaryManager()->GetAggression();
            if(!unknown && hostile>0.f && rush::Score(own,hostile,p.sustainedRushRatio,aggression)>=0.f) {
                key=rushes.Start(rushCandidates,p.sustainedRushRemaining,
                    int(p.sustainedRushCooldown*FRAMES_PER_SEC));
                circuit->LOG("RUSH: start campaign=%d initial=%u members=%u own=%.0f enemy=%.0f aggression=%.3f score=%.3f",
                    key,fronts,unsigned(rushCandidates.size()),own,hostile,aggression,
                    rush::Score(own,hostile,p.sustainedRushRatio,aggression));
            }
        }
    }
    static const bool verify=std::getenv("CIRCUIT_VERIFY_RANGED_QUERIES")!=nullptr;
    if(verify && !rushes.Valid())
        circuit->LOG("[INVARIANT] INV-196 local rush membership or original-front casualty accounting is inconsistent");
    if(key>=0) {
        g.sustainedRush=true; g.committed=true; g.mode=cohort::Mode::RUSH;
        g.radius=unit->GetCircuitDef()->GetMaxRange()*p.sustainedRushRange;
        g.formationRear=false;
    } else if(g.rushFallback) {
        g.committed=false; g.assault.clear(); g.mode=cohort::Mode::WITHDRAW;
        g.radius=std::max(g.radius,unit->GetCircuitDef()->GetMaxRange()+p.spacing*3.f);
    }
}

float CRangedWorld::EffectiveDps(CCircuitDef* def,int armor,int category,
    const AIFloat3& from,const AIFloat3& to,float horizon,bool advancing)
{
    float dps=0.f;
    const float distance=std::sqrt(from.SqDistance2D(to));
    for(const auto& w:CapabilitiesFor(def).weapons) {
        if(!(w.category&category) || armor<0 || size_t(armor)>=w.damage.size()) continue;
        const float reach=Range(w,from,to);
        const float weight=advancing?cohort::ReadyWeight(distance,reach,def->GetSpeed(),horizon)
                                    :(distance<=reach?1.f:0.f);
        // Support behind a hill must not buy permission for an exposed push.
        // An advancing member's final trajectory is checked by its shooter.
        if(weight<=0.f || (!advancing && !Trajectory(w,from,to))) continue;
        dps+=w.damage[armor]*w.alphaScale/w.reload*weight;
    }
    return dps;
}

void CRangedWorld::AssessCohort(CCircuitUnit* unit,CohortPlan& g,const Contact& enemy,float range)
{
    const int now=circuit->GetLastFrame();
    auto* def=unit->GetCircuitDef(); const auto& p=def->GetRangedPolicy();
    const float horizon=p.engagementSeconds, firing=range*p.rangeFraction;
    AIFloat3 firingPoint=enemy.pos+g.back*firing;
    const auto* area=circuit->GetTerrainManager()->GetAreaData();
    // KI-571: a valid enemy plus a firing offset can lie beyond any map edge.
    // Bound the assessment point before the unchecked terrain lookup. Do not
    // change the shared height sampler's contract or clamp only its index.
    if (!terrain_geometry::BoundHeightPoint(firingPoint.x,firingPoint.z,
            area->heightMapXSize,area->heightMap.size(),SQUARE_SIZE)) {
        g.committed=false; g.supporting=false; g.assault.clear();
        g.mode=cohort::Mode::HOLD; g.reason=cohort::Reason::UNREACHABLE;
        g.focus=g.center; g.radius=0.f; g.loss=0.f; g.advantage=0.f;
        return;
    }
    firingPoint.y=area->GetElevationAt(firingPoint.x,firingPoint.z);
    cohort::Force own,hostile;
    g.supporting=false; g.screenDepth=firing;
    float danger=0.f;
    bool uncertain=false,forbidden=false,staticCoverage=false;
    int hostileArmed=0;
    g.assault.clear();
    const int armor=MetadataFor(def).armor;
    // One enemy pass plus one friendly bucket pass per cohort plan. Weapon
    // facts are immutable per-definition caches. There is no friend/enemy
    // Cartesian product, inventory callback, or cross-thread engine access.
    for(int index:g.candidates) {
        const auto& c=contacts[index];
        if(!c.def) { if(c.pos.SqDistance2D(firingPoint)<600.f*600.f) uncertain=true; continue; }
        if(c.def->IsAbleToFly() || c.pos.y< -20.f) continue;
        const float builderReach=c.def->IsAbleToReclaim()?c.def->GetBuildDistance()+c.radius:0.f;
        const float specialReach=std::max(c.explosionRadius,builderReach)+p.safetyMargin;
        if((specialReach>p.safetyMargin && ranged::SegmentDistanceSq(P(c.pos),P(g.center),P(firingPoint))<specialReach*specialReach)
            || (c.def->IsEnemyRoleAny(CCircuitDef::COMM) && firingPoint.SqDistance2D(c.pos)<std::pow(c.hazardRadius+p.spacing,2.f))) forbidden=true;
        const bool covers=c.armed && (ranged::SegmentDistanceSq(P(c.pos),P(g.center),P(firingPoint))
            <std::pow(c.hazardRadius+p.safetyMargin,2.f)
            || (c.mobile && c.pos.SqDistance2D(enemy.pos)<600.f*600.f));
        if(!covers && c.id!=enemy.id) continue;
        if(!c.los) uncertain=true;
        hostile.health+=c.health;
        hostile.value+=cohort::HealthValue(c.cost,c.health,c.def->GetHealth());
        if(c.armed) {
            ++hostileArmed;
            // Moving opponents can close during the same horizon. Static
            // coverage is evaluated at our intended firing band, not the
            // current safe staging point outside it.
            hostile.dps+=EffectiveDps(c.def,armor,def->GetCategory(),c.pos,firingPoint,horizon,c.mobile);
            const float reach=c.hazardRadius+p.safetyMargin;
            const auto relative=c.pos-enemy.pos;
            const float along=Projection(relative,g.back);
            const float lateral=std::max(0.f,relative.SqLength2D()-along*along);
            if(lateral<reach*reach) danger=std::max(danger,along+std::sqrt(reach*reach-lateral));
            if(!c.mobile) {
                staticCoverage=true;
                // A small explicit permission set keeps segment checks O(H)
                // for H local hazards. Larger batteries remain excluded.
                if(g.assault.size()<8) g.assault.push_back(c.id); else forbidden=true;
                if(Progress(c.id,p.repairedTargetPenalty)<1.f) forbidden=true;
            }
        }
    }
    // Lazy combat-health callbacks are memoized in the frame's Friend entry;
    // overlapping cohorts share those observations. Artillery-only games pay
    // none of this cost. Count only physically useful allied fire support.
    EnsureAllies();
    allies.Query(P(enemy.pos),1400.f,[&](int index) {
        auto& f=friends[index];
        if(!f.def || !f.def->IsAttacker()) return;
        const auto member=membership.find(f.id);
        const bool ours=member!=membership.end() && membership.at(unit->GetId())==member->second;
        const float dps=EffectiveDps(f.def,enemy.armor,enemy.def->GetCategory(),f.pos,enemy.pos,horizon,ours);
        if(dps<=0.f) return;
        if(f.combatHealth<0.f) f.combatHealth=circuit->GetUnitAPI()->GetCombatHealth(f.id);
        if(f.combatHealth<=0.f) return;
        const float fraction=std::clamp(f.combatHealth/f.def->GetHealth(),0.f,1.f);
        // Low-health units are handed to the existing retreat/repair task;
        // their presence cannot authorize another cohort to spend their HP.
        if(fraction<.35f) return;
        own.dps+=dps;
        const float alliedRange=f.def->GetMaxRange(CCircuitDef::RangeType::LAND);
        // Another Thug cohort contributes firepower, but is not a fragile
        // support line. Treating newly admitted/merging Thugs as rocket support
        // accidentally enabled screening exposure in ordinary kite duels.
        const bool supporting=p.supportAllies && !ours && (!f.def->GetRangedPolicy().coordinated
                || f.def->GetRangedPolicy().formationPosition == RangedPolicy::FormationPosition::REAR) && f.def->IsMobile()
            && !f.def->IsAbleToFly() && f.pos.SqDistance2D(g.center)<p.cohortRadius*p.cohortRadius;
        if(supporting) {
            g.supporting=true;
            // Rocket/artillery hulls currently contributing fire get a screen
            // ahead of them on the shared combat axis, not a ring around base.
            if(alliedRange>range) g.screenDepth=std::min(g.screenDepth,
                // Do not follow an overextended rocket bot into point-blank
                // fire. Screen near our own firing band, rather than treating
                // "ahead of support" as permission to throw away weapon range.
                std::max(range*.90f,Projection(f.pos-enemy.pos,g.back)-p.spacing));
        }
        if(ours || (f.def->IsMobile() && !f.def->IsAbleToFly()
            && (f.pos.SqDistance2D(firingPoint)<256.f*256.f
                || (supporting && alliedRange<=range && f.pos.SqDistance2D(enemy.pos)<range*range)))) {
            const float weight=cohort::ReadyWeight(std::sqrt(f.pos.SqDistance2D(enemy.pos)),range,def->GetSpeed(),horizon);
            own.health+=f.combatHealth*weight;
            own.value+=cohort::HealthValue(f.def->GetCostM(),f.combatHealth,f.def->GetHealth())*weight;
            if(weight>0.f) own.hullHealth=own.hullHealth>0.f?std::min(own.hullHealth,f.combatHealth):f.combatHealth;
        }
    });
    const float distance=std::sqrt(g.center.SqDistance2D(enemy.pos));
    AIFloat3 pursuit=enemy.pos-g.center; pursuit.Normalize2D();
    const float fleeing=std::max(0.f,Projection(enemy.velocity,pursuit));
    const float closing=def->GetSpeed()-fleeing;
    const float approach=distance<=range?0.f:(closing>1.f?(distance-range)/closing:horizon);
    // A screening force accepts repairable damage to save allies already in
    // range. Keep the same metal-exchange check and hard hazard vetoes. Static
    // batteries never inherit this mobile-support allowance. JSON controls the
    // HP budget; low-health hulls still leave through the normal retreat task.
    const bool screening=g.supporting && !staticCoverage;
    const float limit=staticCoverage?p.staticLossFraction:
        screening?std::max(p.lossFraction,p.supportLossFraction):p.lossFraction;
    // Preserve the established dodging/repair policy at a neutral slider.
    // Automatic army balance influences rush admission; only the explicit
    // user offset changes ordinary engagement/withdrawal risk tolerance.
    const float bias=p.sustainedRush?circuit->GetMilitaryManager()->GetAggressionDelta():0.f;
    const float caution=std::clamp(1.f-.5f*bias,.5f,1.5f);
    const auto result=cohort::Assess(own,hostile,horizon,approach,p.advantageEnter*caution,p.advantageExit*caution,limit/caution,
        g.committed || screening,screening?hostileArmed:1);
    g.loss=result.loss; g.advantage=result.advantage;
    g.committed=result.commit && !uncertain && !forbidden && approach<=p.catchSeconds;
    if(staticCoverage && p.staticLossFraction<=0.f) g.committed=false;
    if(!g.committed) g.assault.clear();
    g.reason=g.committed?cohort::Reason::FAVORABLE:forbidden?cohort::Reason::STATIC
        :uncertain?cohort::Reason::UNKNOWN:approach>=horizon?cohort::Reason::UNREACHABLE:cohort::Reason::OUTMATCHED;
    g.radius=firing;
    g.mode=cohort::Mode::ADVANCE;
    if(g.committed) {
        g.mode=cohort::Mode::RUSH;
        if(g.supporting) g.radius=std::min(g.radius,g.screenDepth);
    }
    else if(danger>firing) { g.radius=danger+p.hysteresis; g.mode=cohort::Mode::WITHDRAW; }
    // Assemble once for this contact. Late arrivals occupy vacancies/catch up;
    // they never reset a timer or move the ready core back toward the factory.
    if(g.assemblyTarget!=enemy.id) {
        g.assemblyTarget=enemy.id; g.regroupUntil=now+int(p.regroupSeconds*FRAMES_PER_SEC);
    }
    unsigned ready=0;
    for(int member:g.members) {
        auto* u=circuit->GetTeamUnit(member);
        if(u && cohort::Admit(P(u->GetPos(now)),P(g.center),p.cohortRadius*.5f)) ++ready;
    }
    if(!g.supporting && now<g.regroupUntil && ready*4<g.members.size()*3 && distance>enemy.hazardRadius+p.spacing) {
        g.committed=false; g.assault.clear(); g.mode=cohort::Mode::REGROUP; g.reason=cohort::Reason::ASSEMBLE;
        g.radius=std::max(firing,distance); // hold vanguard; do not pull it rearward
    }
}

bool CRangedWorld::CohortSafe(CCircuitUnit* unit,const AIFloat3& from,const AIFloat3& to,float margin,bool escaping)
{
    const auto& g=PlanCohort(unit);
    // Sustained assault deliberately spends the local force until its fixed
    // original front roster reaches the configured loss threshold. Terrain,
    // path ownership, target legality and friendly-fire checks still apply.
    if(g.sustainedRush) return true;
    const AIFloat3 center=(from+to)*.5f;
    const float radius=std::sqrt(from.SqDistance2D(to))*.5f+largestCohortHazard+margin;
    // Keep the generic Safe predicate unchanged for every other ranged unit.
    // Fresh unknown crossfire, a commander or a reclaiming builder invalidates
    // this segment immediately, including an in-flight path's completion.
    const auto blocked=[&](int index) {
        const auto& c=contacts[index]; if(!c.def || c.def->IsAbleToFly() || c.pos.y< -20.f) return false;
        float special=c.explosionRadius;
        if(c.def->IsAbleToReclaim()) special=std::max(special,c.def->GetBuildDistance()+c.radius);
        if(c.def->IsEnemyRoleAny(CCircuitDef::COMM)) special=std::max(special,c.hazardRadius);
        if(special>0.f && !ranged::SafeSegment(P(from),P(to),P(c.pos),special+margin)) return true;
        if(c.mobile || c.hazardRadius<=0.f) return false;
        if(g.committed && std::find(g.assault.begin(),g.assault.end(),c.id)!=g.assault.end()) return false;
        return escaping?!ranged::SafeSegment(P(from),P(to),P(c.pos),c.hazardRadius+margin)
            :ranged::SegmentDistanceSq(P(c.pos),P(from),P(to))<std::pow(c.hazardRadius+margin,2.f);
    };
    const bool safe=!enemies.Any(P(center),radius,blocked);
    static const bool verify=std::getenv("CIRCUIT_VERIFY_RANGED_QUERIES")!=nullptr;
    if(verify) {
        // Test-only brute-force oracle catches an undersized spatial bound.
        // The production path above remains O(local hazards), allocation-free.
        bool reference=true;
        for(size_t i=0;i<contacts.size();++i) if(blocked(int(i))) { reference=false; break; }
        if(reference!=safe) circuit->LOG("[INVARIANT] INV-173 cohort segment query omitted a known weapon, blast or reclaim exclusion unit=%d",unit->GetId());
    }
    return safe;
}
}
