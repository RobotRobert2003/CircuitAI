#ifndef CIRCUIT_RANGED_POLICY_H
#define CIRCUIT_RANGED_POLICY_H

#include <string>

namespace circuit {
// JSON owns policy. The RANGED attribute is the only admission switch; these
// values do not change legacy siege, squad, naval, air or specialist owners.
struct RangedPolicy {
    enum class Mode { PRECISION, SKIRMISH, BOMBARDMENT, CARRIER };
    // Empty family preserves every existing controller. Formation roles are
    // policy, not unit names: same-family homogeneous cohorts may pair.
    enum class FormationPosition { NONE, FRONT, REAR };
    std::string formationFamily;
    FormationPosition formationPosition = FormationPosition::NONE;
    float formationSeparationMinimum = 64.f, formationSeparationMaximum = 96.f;
    float withdrawalLeadSeconds = 0.f;
    Mode mode = Mode::SKIRMISH;
    float rangeFraction = .95f;
    float spacing = 96.f;
    float safetyMargin = 48.f;
    float hysteresis = 48.f;
    float reactionSeconds = 1.f;
    float targetHysteresis = 1.2f;
    float sensorOffset = 160.f;
    float cloakReserve = 3.f;
    float repairedTargetPenalty = .25f;
    float splashWeight = .5f;
    bool cloakOnReload = false;
    bool allowMobile = true;
    bool allowStatic = true;
    bool preferHeavy = false;
    bool preferScreen = true;
    bool allowRadar = true;
    bool advanceUnknownRadar = true;
    bool holdFireline = false; // opt-in forward-fire policy: hold under pressure, never kite
    bool stageWhenBlocked = false; // opt-in: deploy outside coverage if no firing band fits
    bool coordinated = false; // local same-type firing cohorts, not legacy siege
    float cohortSize = 12.f;
    float cohortRadius = 900.f;
    float regroupSeconds = 8.f;
    float rushRatio = 1.75f;
    float catchSeconds = 6.f;
    // Zero preserves the original coordinated controller for profiles which
    // do not explicitly opt into outcome-based engagement.
    float engagementSeconds = 0.f;
    bool sustainedRush = false;
    float sustainedRushRatio = 2.f, sustainedRushRadius = 900.f;
    float sustainedRushMinFront = 8.f, sustainedRushRemaining = .25f;
    float sustainedRushCooldown = 20.f, sustainedRushRange = .80f;
    float advantageEnter = 1.4f, advantageExit = 1.1f;
    float lossFraction = .35f, staticLossFraction = 0.f;
    bool supportAllies = false; // opt-in frontline screening; never waives hard hazards
    float supportLossFraction = 0.f; // explicit HP budget when joining an allied mobile engagement
    float intentGain = 0.f; // required relative endpoint improvement; zero preserves old micro
    // D-294: per-shooter target exclusion, resolved once from JSON
    // "avoid_categories" (BAR category names, e.g. "GROUNDSCOUT"). Zero = none.
    // Excluded contacts are never targeted, approached or escaped from; they
    // remain hazards in CRangedWorld::Safe/DangerSign. O(1) AND per candidate.
    int avoidCategory = 0;
    // D-301: score multiplier for a contact that heals or rebuilds the enemy
    // line (a static repairer: construction turret; or a resurrection unit),
    // applied only among targets already in weapon range. It never moves a
    // unit, widens target permission or waives a hazard. Zero = off.
    float repairerFocus = 0.f;
    // D-294: 0 = off. Penalise a mobile target whose drift during projectile
    // flight exceeds evasionLimit*(splash+target radius); see ranged::Evasive.
    float evasionLimit = 0.f;
    // D-295: 0 = off. With no legal shot, seek the nearest LOS contact within
    // this radius that an allied screen is already fighting (CRangedWorld::Engaged).
    // Individual (non-coordinated) controller only.
    float assistRadius = 0.f;
    float assistMargin = 150.f; // ally counts as engaged within its ground range + margin + contact radius
    bool assistScreen = true;   // assist firing sites require an allied screen toward the target
};
}
#endif
