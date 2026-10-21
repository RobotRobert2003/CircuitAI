// Edge lane forward porc (owner, 2026-10-19; systems/combat/edge_porc.as): the
// two edge-lane FRONTs (EdgeLanes::Decide) each build two small porc clusters on
// their own map edge, EdgePorcShares (25 % and 40 %) of the way from our starts to the enemy's,
// where enemy spam walks along the edge. Cheap guns first, then the T2 pop-up,
// then the T2 long-range plasma, then T2 flak, each step gated on the sustained (10 s minimum)
// metal and energy income.
namespace Global { namespace Spam {
    bool EdgePorcEnabled = false;          // on in experimental_balanced
    // One cluster at each share along the axis, our starts' centre (0) to the enemy's (1);
    // owner, 2026-10-19: 25 % added beside the 40 % one; the nearer one builds each step first
    array<float> EdgePorcShares = { 0.25f, 0.40f };
    float EdgePorcInset = 300.0f;          // the cluster centre stands this far in from the edge point
    float EdgePorcRadius = 700.0f;         // our guns within this of the centre count as built
    float EdgePorcShake = 160.0f;          // native looks this far round a slot for room
    // light = Beamer / Twin Guard / Cacophony, mid = Pit Bull / Scorpion / Chimera,
    // heavy = Rattlesnake / Persecutor / Eviscerator, flak = the T2 flak (Flak Cannon) of each faction
    dictionary EdgePorcLight = { {"armada", "armbeamer"}, {"cortex", "corhllt"}, {"legion", "legmg"} };
    dictionary EdgePorcMid = { {"armada", "armpb"}, {"cortex", "corvipe"}, {"legion", "legapopupdef"} };
    dictionary EdgePorcHeavy = { {"armada", "armamb"}, {"cortex", "cortoast"}, {"legion", "legacluster"} };
    dictionary EdgePorcFlak = { {"armada", "armflak"}, {"cortex", "corflak"}, {"legion", "legflak"} };
    // The ladder, in order: tier (0 light, 1 mid, 2 heavy, 3 flak), how many of that tier
    // should stand once the step is done, and the sustained incomes it needs.
    // Owner, 2026-10-19: a last step of two T2 flak after the long-range plasma.
    array<int> EdgePorcTier = { 0, 0, 1, 0, 1, 2, 1, 2, 3 };
    array<int> EdgePorcCount = { 1, 2, 1, 3, 2, 1, 3, 2, 2 };
    array<float> EdgePorcMetal = { 25.0f, 35.0f, 50.0f, 60.0f, 75.0f, 95.0f, 115.0f, 140.0f, 160.0f };
    array<float> EdgePorcEnergy = { 250.0f, 400.0f, 700.0f, 800.0f, 1100.0f, 1500.0f, 1800.0f, 2400.0f, 3000.0f };
} }
