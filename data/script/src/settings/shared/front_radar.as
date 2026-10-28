// Front radar (owner, 2026-10-27; systems/combat/front_radar.as): long-range
// radars (armarad / corarad / legarad) just behind our front-most mexes and
// guns, on top of the porc chain's one per well-funded defence point.
namespace Global { namespace FrontRadar {
    bool Enabled = false;                  // on in experimental_balanced
    bool Report = false;                   // log the radar census even while Enabled is off (baseline tests)
    bool FrontRoleOnly = true;             // only a FRONT orders them; every role still reports its radars to allies
    // The ladder: step k wants k+1 of our long-range radars standing at the front
    // once the sustained (10 s minimum) metal and energy income reach it.
    array<float> Metal = { 60.0f, 100.0f, 150.0f, 220.0f };
    array<float> Energy = { 1200.0f, 2000.0f, 3000.0f, 4500.0f };
    float Depth = 1500.0f;      // anchors (finished mexes and guns) up to this much farther from the enemy than our front-most one are front
    float Back = 450.0f;        // the radar stands this far behind its anchor, toward our start
    float Spacing = 2200.0f;    // no front radar this close to another long-range radar, ours or an allied SMRTBARb's
    float MaxThreat = 1.0f;     // enemy surface threat at the site above this: that anchor is skipped for now
    float Shake = 200.0f;       // native looks this far round the site for room
    int FailSeconds = 180;      // a site whose order died with no radar is skipped this long
    int LostSeconds = 600;      // a spot where one of our long-range radars died is skipped this long, doubled per further loss there
    int LostMaxSeconds = 2400;  // cap on that doubling
    int OrderSeconds = 300;     // an order with no radar frame near its site this long after it was placed is aborted
    int ReportSeconds = 120;    // census line interval
    int BroadcastSeconds = 60;  // our radar list goes to the allies at least this often
    // Ghost radars (owner, 2026-10-27): the FRONT commander's "radar_ghost" ladder rung
    // (commander.json front_ladder) puts a T1 radar where it reaches the last-known
    // images of enemy structures that neither our team's radar nor LOS covers now.
    bool GhostEnabled = false;          // on in experimental_balanced
    float GhostRadarRange = 2100.0f;    // T1 radar (armrad / corrad / legrad) radardistance
    float GhostT2RadarRange = 3500.0f;  // long-range radar radardistance
    float GhostCoverage = 0.85f;        // an image within this fraction of a radar's range counts as reached
    float GhostTravel = 800.0f;         // the commander walks at most this far to the site
    float GhostMaxThreat = 1.0f;        // enemy surface threat at the site above this: skipped
    float GhostShake = 96.0f;           // native looks this far round the site for room
    float GhostFailRadius = 400.0f;     // a failed order blocks sites this close to it
    int GhostMaxCandidates = 48;        // unreached images considered per ask
    int GhostIntervalSeconds = 20;      // least time between two ghost radar orders of this AI
    int GhostOrderSeconds = 60;         // native timeout of the order; one with no radar frame this long after it was placed is aborted
    int GhostFailSeconds = 180;         // a spot whose order died with no radar is skipped this long
    int GhostAllySeconds = 90;          // an allied SMRTBARb's ghost order counts as a radar this long
} }
