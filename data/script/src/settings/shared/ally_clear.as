// Ally clear (owner, 2026-10-17; systems/team/ally_clear.as): TECH and AIR may
// reclaim an allied SMRTBARb's T1 porc and T1 eco inside their blocked planned
// sites (construction-turret blocks, T2 factories, spam factories). Never humans.
namespace Global { namespace Team {
    bool AllyClearEnabled = false;            // on in experimental_balanced
    float AllyClearReplySeconds = 15.0f;      // a site waits this long for the allies' answers
    float AllyClearReclaimSeconds = 120.0f;   // ... and at most this long for the given buildings to be reclaimed
    float AllyClearRetrySeconds = 300.0f;     // the same site is asked about again after this
    // T1 porc: every land defence a T1 bot/vehicle constructor builds (owner's list, 2026-10-17)
    array<string> AllyClearPorc = {
        "armllt", "armbeamer", "armhlt", "armclaw", "armrl", "armferret", "armcir",
        "corllt", "corhllt", "corhlt", "cormaw", "corrl", "cormadsam", "corerad",
        "leglht", "legmg", "leghive", "legdtr", "legrl", "legrhapsis", "leglupara" };
    // T1 eco: winds, solars, T1 converters, energy storage (owner's list, 2026-10-17)
    array<string> AllyClearEco = {
        "armwin", "armsolar", "armmakr", "armestor",
        "corwin", "corsolar", "cormakr", "corestor",
        "legwin", "legsolar", "legeconv", "legestor" };
    // T1 construction turrets, land and floating (owner, 2026-10-20)
    array<string> AllyClearTurrets = {
        "armnanotc", "armnanotcplat", "cornanotc", "cornanotcplat", "legnanotc", "legnanotcplat" };
    // T2 radars and T2 jammers (owner, 2026-10-20)
    array<string> AllyClearIntel = {
        "armarad", "corarad", "legarad", "armveil", "corshroud", "legajam" };
    // TECH's economy ground (owner, 2026-10-20): its turret box, the box grown
    // behind it and the forward cluster are asked about as well as blocked
    // factory sites, each at most once per AllyClearRetrySeconds (only while
    // AllyClearEnabled, which experimental_balanced turns on)
    bool AllyClearEcoAsk = true;
} }
