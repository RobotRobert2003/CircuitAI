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
    int ReportSeconds = 120;    // census line interval
    int BroadcastSeconds = 60;  // our radar list goes to the allies at least this often
} }
