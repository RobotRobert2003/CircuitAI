#include "task/fighter/RangedWorld.h"
#include "terrain/GroundFormation.h"
#include "CircuitAI.h"
#include "unit/CircuitUnit.h"
#include "util/Utils.h"
#include "Log.h"

namespace circuit {
// Linked homogeneous cohorts preserve per-definition weapon/armor arithmetic.
// Callback-thread ownership, IDs only, no engine access from path workers.
// One local spatial query on a missing link; a retained reciprocal link costs
// map lookups and one distance check. Never scan all formations per shooter.
const CRangedWorld::CohortPlan& CRangedWorld::PlanCohort(CCircuitUnit* unit)
{
    PlanIndependentCohort(unit);
    const int key=membership.at(unit->GetId());
    auto& rear=cohorts.at(key);
    ApplyRush(unit,rear);
    if(rear.sustainedRush || rear.rushFallback) return rear;
    const auto& policy=unit->GetCircuitDef()->GetRangedPolicy();
    if(policy.formationPosition!=RangedPolicy::FormationPosition::REAR) return rear;
    const int now=circuit->GetLastFrame();
    // Positive and negative decisions are shared by the whole cohort. All
    // membership writers invalidate both partners before another callback.
    if(rear.formationFrame==now) return rear;
    const auto compatible=[&](int candidate, bool retained) {
        auto found=cohorts.find(candidate);
        if(found==cohorts.end() || found->second.members.empty()) return false;
        auto& front=found->second;
        auto* leader=circuit->GetTeamUnit(front.members.front());
        if(!leader || leader->IsDead()) return false;
        const auto& other=leader->GetCircuitDef()->GetRangedPolicy();
        if(other.formationPosition!=RangedPolicy::FormationPosition::FRONT) return false;
        // A stale reservation from an erased/merged cohort is available again.
        if(front.formationPartner>=0 && front.formationPartner!=key) {
            auto owner=cohorts.find(front.formationPartner);
            if(owner!=cohorts.end() && owner->second.formationPartner==candidate) return false;
        }
        return formation::Compatible(policy.formationFamily==other.formationFamily,
            leader->GetArea()==unit->GetArea(),true,
            leader->GetPos(now).SqDistance2D(rear.center),policy.cohortRadius,retained);
    };
    const int previousPartner=rear.formationPartner;
    if(!compatible(rear.formationPartner,true)) {
        auto previous=cohorts.find(rear.formationPartner);
        if(previous!=cohorts.end() && previous->second.formationPartner==key)
            previous->second.formationPartner=-1;
        rear.formationPartner=-1;
        rear.formationRear=false;
        float nearest=policy.cohortRadius*policy.cohortRadius;
        // Pair by actual positions, not projected destination slots: a long
        // route may reserve a point far beyond two physically adjacent groups.
        EnsureAllies();
        allies.Query({rear.center.x,rear.center.z},policy.cohortRadius,[&](int index) {
            auto member=membership.find(friends[index].id);
            if(member==membership.end() || !compatible(member->second,false)) return;
            auto* leader=circuit->GetTeamUnit(cohorts.at(member->second).members.front());
            const float distance=leader->GetPos(now).SqDistance2D(rear.center);
            if(distance<nearest || (distance==nearest && member->second<rear.formationPartner)) {
                nearest=distance; rear.formationPartner=member->second;
            }
        });
    }
    if(rear.formationPartner<0) { rear.formationFrame=now; return rear; } // standalone rockets remain useful
    auto* leader=circuit->GetTeamUnit(cohorts.at(rear.formationPartner).members.front());
    // Front planning can merge its group. Reacquire by membership afterwards;
    // std::map references to the independent rear group remain valid.
    PlanIndependentCohort(leader);
    rear.formationPartner=membership.at(leader->GetId());
    auto& front=cohorts.at(rear.formationPartner);
    front.formationPartner=key;
    if(previousPartner!=rear.formationPartner)
        circuit->LOG("FORMATION: linked front=%d rear=%d members=%u/%u",rear.formationPartner,key,
            unsigned(front.members.size()),unsigned(rear.members.size()));
    rear.formationFrame=now;
    rear.formationRear=false;
    const auto& frontPolicy=leader->GetCircuitDef()->GetRangedPolicy();
    const float frontRange=leader->GetCircuitDef()->GetMaxRange()*frontPolicy.rangeFraction;
    const float rearRange=unit->GetCircuitDef()->GetMaxRange()*policy.rangeFraction;
    const float separation=formation::Separation(frontRange,rearRange,
        policy.formationSeparationMinimum,policy.formationSeparationMaximum);
    // A rocket can outrange a turret that the screen cannot. Requiring it
    // to sit behind an already withdrawn screen would put both out of range.
    // Keep its independently admitted safe firing band in that case. This is
    // a siege deployment, not permission to pull Thugs into static coverage.
    if(front.mode==cohort::Mode::WITHDRAW && rear.target==front.target
        && rear.mode!=cohort::Mode::WITHDRAW && rear.radius<front.radius+separation)
        return rear;
    rear.formationRear=true;
    rear.formationScreenOffset=separation;
    // Share intent, never share permission to rush through a hazard. The rear
    // controller still evaluates its own trajectory, slot and escape safety.
    rear.target=front.target; rear.focus=front.focus; rear.back=front.back;
    rear.mode=front.mode==cohort::Mode::RUSH ? cohort::Mode::ADVANCE : front.mode; rear.committed=false; rear.assault.clear();
    rear.radius=formation::RearRadius(front.radius,frontRange,rearRange,
        policy.formationSeparationMinimum,policy.formationSeparationMaximum);
    if(front.target<0) rear.focus+=front.back*separation;
    // Preserve useful, legal independent fire even while following a screen.
    // Individual target selection is deliberately separate from this objective.
    return rear;
}
}
