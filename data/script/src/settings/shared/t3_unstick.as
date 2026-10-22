// T3 unstick (owner, 2026-10-20; systems/combat/t3_unstick.as): a T3 unit that
// stops moving while it has an order, hemmed in by our T1 porc, T1 eco or T1
// construction turrets, gets those structures reclaimed by nearby construction
// turrets and T1/T2 constructors, then is sent on toward the enemy.
namespace Global { namespace T3Unstick {
    bool Enabled = false;                 // on in experimental_balanced
    float MinMetal = 2500.0f;             // a mobile ground unit this costly counts as T3 even when not from a gantry
    float StuckSeconds = 20.0f;           // ... stuck after this long within StuckRadius while it has a fighter task
    float StuckRadius = 96.0f;            // elmos
    float GraceSeconds = 15.0f;           // after it is finished, before the clock starts
    float PenGap = 64.0f;                 // a structure is penning it when its footprint is within this of the unit's
    int MaxRounds = 3;                    // each round widens the ring by PenGap; then the unit is left alone
    float RetrySeconds = 45.0f;           // between rounds for the same unit
    float ReclaimSeconds = 90.0f;         // a round gives up on its reclaims after this
    float BuilderRange = 2000.0f;         // mobile T1/T2 constructors this close to a blocker help
    float TurretMargin = 32.0f;           // construction turrets within build range + this join each reclaim
    int BuildersPerBlocker = 2;
    float NudgeDistance = 600.0f;         // after a round, one move this far toward the nearest enemy start
    // A cleared blocker's site leaves TECH's plans (owner, 2026-10-22): the
    // native layout slot is forgotten on reclaim (D-101); the script plans
    // (weapon slots, fortifications, forward defence, eco flak) skip these.
    int MaxCleared = 64;                  // oldest dropped first
    // Engine (CircuitAI.cpp UnitMoveFailed): after 40 failed moves it stops the
    // unit and orders it reclaimed. For a T3 that reclaim is aborted here and
    // treated as the stuck signal.
    bool AbortSelfReclaim = true;
    // Cleared on top of AllyClearPorc (T1 porc), AllyClearEco (T1 eco) and T1
    // construction turrets (owner, 2026-10-20): T2 flak and the T2 pop-up
    // artillery (Rattlesnake, Persecutor, Eviscerator).
    array<string> ExtraClear = {
        "armflak", "corflak", "legflak",
        "armamb", "cortoast", "legacluster" };
} }
