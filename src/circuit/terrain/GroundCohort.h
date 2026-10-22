#ifndef CIRCUIT_GROUND_COHORT_H
#define CIRCUIT_GROUND_COHORT_H
#include "terrain/RangedGeometry.h"

namespace circuit::cohort {
enum class Mode { ADVANCE, HOLD, KITE, WITHDRAW, RUSH, REGROUP };
enum class Reason { TRAVEL, FAVORABLE, HOLD_FIRE, OUTMATCHED, UNREACHABLE, UNKNOWN, STATIC, ASSEMBLE };
struct Force {
    float health=0.f, dps=0.f, value=0.f;
    float hullHealth=0.f;
};
struct Assessment {
    bool commit=false;
    float loss=1.f, advantage=0.f, seconds=0.f;
};
// A finite-horizon estimate, not a combat simulator. Arrival/readiness and
// armor-adjusted DPS are supplied by the caller. Price limits the metal put
// at risk; it does not stand in for HP or weapon effectiveness. Hysteresis
// separates entering a fight from retaining it as observations fluctuate.
inline Assessment Assess(const Force& own, const Force& enemy, float horizon,
                         float approach, float entry, float exit, float lossLimit,
                         bool committed, int focusTargets=1) {
    Assessment result;
    if(own.health<=0.f || own.dps<=0.f || horizon<=0.f || approach>=horizon) return result;
    result.seconds=std::min(horizon-approach,enemy.health/own.dps);
    const float dealt=std::min(enemy.health,own.dps*result.seconds);
    const float ourFraction=dealt/std::max(1.f,enemy.health);
    // Opt-in allied screening estimates focused kills in a multi-unit force:
    // the last hull keeps firing until the end; earlier kills remove DPS.
    // Full incoming fire is retained throughout approach and against a single
    // hull. This is an estimate, not permission to ignore actual damage or
    // fresh static coverage. Ordinary duels/static admission keep N=1 exactly.
    const float attrition=focusTargets>1 ? .5f*ourFraction*(1.f-1.f/focusTargets) : 0.f;
    const float received=enemy.dps*(approach+result.seconds*(1.f-attrition));
    result.loss=std::clamp(received/own.health,0.f,1.f);
    result.advantage=ourFraction/std::max(.01f,result.loss);
    // Repairable damage is not destroyed metal. Budget HP loss separately,
    // then conservatively concentrate incoming damage on the weakest ready
    // hull when estimating casualties. Without hull data retain the old
    // fractional estimate rather than inventing a unit size.
    const float lostHealth=own.hullHealth>0.f ? std::floor(received/own.hullHealth)*own.hullHealth : received;
    const float metalLost=own.value*std::min(1.f,lostHealth/own.health);
    const float metalGained=enemy.value*ourFraction;
    result.commit=result.loss<=lossLimit && result.advantage>=(committed?exit:entry)
        && (enemy.dps<=0.f || metalGained>=(committed?exit:entry)*metalLost);
    return result;
}
inline float ReadyWeight(float distance,float reach,float speed,float horizon) {
    const float delay=std::max(0.f,distance-reach)/std::max(1.f,speed);
    return std::clamp(1.f-delay/std::max(.1f,horizon),0.f,1.f);
}
inline float RelativeClosing(ranged::Point from,ranged::Point velocity,
                             ranged::Point enemy,ranged::Point enemyVelocity) {
    return ranged::ClosingSpeed(from,enemy,{enemyVelocity.x-velocity.x,enemyVelocity.z-velocity.z});
}
inline float KiteStep(float penetration,float hysteresis,bool disengage) {
    return std::max(disengage?192.f:32.f,penetration+hysteresis);
}
// A short escape is useful only when the firing band can hold the engine's
// arrival tolerance plus one configured reaction interval. Narrow advantages
// (Thug versus Centurion: 55 elmos) retain the established full escape; repeated
// short STOP/turn cycles there spend the advantage before the hull accelerates.
inline bool ShortKite(float ownRange,float enemyRange,float speed,float reaction) {
    return ownRange-enemyRange>64.f+speed*reaction;
}
// Geometric confidence for replacing a live MOVE. This is not a timer or
// command budget: unsafe paths, changed combat mode/target and escape bypass
// it at the caller. Small equivalent endpoint updates have little benefit.
inline bool KeepMove(ranged::Point from, ranged::Point live, ranged::Point wanted,
                     float gain, float tolerance) {
    const float lx=live.x-from.x, lz=live.z-from.z;
    const float wx=wanted.x-from.x, wz=wanted.z-from.z;
    const float l2=lx*lx+lz*lz, w2=wx*wx+wz*wz, dot=lx*wx+lz*wz;
    if (gain<=0.f || l2<=4096.f || dot<=0.f || dot*dot<.9f*l2*w2) return false;
    const float benefit=std::sqrt(ranged::DistanceSq(live,wanted));
    return benefit<=std::max(tolerance,std::sqrt(w2)*gain);
}
inline bool Admit(ranged::Point recruit,ranged::Point anchor,float radius) {
    return ranged::DistanceSq(recruit,anchor)<=radius*radius;
}
// Same final-waypoint tolerance as the controller's route walker, and the
// existing two-slot neighborhood for a static staging reservation. The caller
// must prove completion, unchanged objective/mode, safety and free spacing.
inline bool CompletedStage(ranged::Point current,ranged::Point completed,
                           ranged::Point desired,float spacing) {
    return ranged::DistanceSq(current,completed)<4096.f
        && ranged::DistanceSq(completed,desired)<4.f*spacing*spacing;
}
// Cost is only a conservative local force proxy. A price advantage never
// substitutes for catchability or surviving the approach. No engine state here.
inline bool CanRush(float ownRange, float enemyRange, float speed, float enemySpeed,
                    float ownValue, float enemyValue, float ratio, float maxCatchSeconds,
                    float distance) {
    const float closing = speed - enemySpeed;
    return enemyRange > ownRange && closing > 1.f && enemyValue > 0.f
        && ownValue >= enemyValue * ratio
        && std::max(0.f,distance-ownRange) / closing <= maxCatchSeconds;
}
// Equal-radius slots bring an arc into range together instead of putting its
// corners outside reach. Bounded to the friendly half; multiple cohorts form
// additional arcs rather than wrapping around behind the enemy.
inline ranged::Point Arc(ranged::Point target, ranged::Point back, float radius,
                         int rank, int count, float spacing) {
    const float angle = std::atan2(back.z, back.x);
    // Arc length is slightly greater than its chord. Using spacing/radius
    // makes adjacent slots fail FreeSlot by a fraction of an elmo.
    const float step = std::min(2.f*std::asin(std::min(.9f,(spacing+1.f)/(2.f*std::max(1.f,radius)))),
                                2.f/std::max(1,count-1));
    const float a = angle + (rank-(count-1)*.5f)*step;
    return {target.x+std::cos(a)*radius, target.z+std::sin(a)*radius};
}
inline float HealthValue(float cost,float health,float maximum) {
    return cost*std::clamp(health/std::max(1.f,maximum),0.f,1.f);
}
// Frontline screens and rear artillery have different formation jobs. Keep
// same-family spacing exact; a mixed pair needs physical room and the smaller
// tactical spacing, not the artillery's anti-chain-explosion exclusion ring.
inline float PairSpacing(float a,float b,bool cohortA,bool cohortB,float radii) {
    return cohortA!=cohortB ? std::max(std::min(a,b),radii) : std::max(a,b);
}
}
#endif
