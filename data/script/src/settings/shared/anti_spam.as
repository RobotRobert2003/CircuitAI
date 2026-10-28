// Anti-spam lanes (owner, 2026-10-27; systems/combat/anti_spam.as): when dozens
// of enemy spam units (Grunts, Pawns ...) have been seen coming down one lane,
// the allied FRONT nearest that lane holds it with guns, Dragon's teeth and
// construction turrets.
namespace Global { namespace AntiSpam {
    bool Enabled = false;                  // on in experimental_balanced
    // What counts as spam: these unit names, plus (CountCheapArmed) any armed
    // mobile ground unit costing at most MaxSpamCost metal.
    array<string> SpamDefs = { "corak", "armpw", "leggob", "armflash", "corgator", "leghades", "armflea", "corfav", "armfav" };
    bool CountCheapArmed = false;
    float MaxSpamCost = 60.0f;
    // Detection: this many different spam units seen within WindowSeconds,
    // inside our half (MinShare..MaxShare of the way from our starts to the enemy's).
    int TriggerCount = 24;
    int WindowSeconds = 300;
    float MinShare = 0.0f;
    float MaxShare = 0.65f;
    // Lanes: sightings are binned sideways across the axis, LaneBin elmos a bin;
    // a lane is a bin (with its two neighbours) holding at least LaneMinShare of
    // the sightings and LaneMinUnits different units. At most MaxLanes lanes;
    // a new lane must be LaneSeparation sideways from a known one.
    float LaneBin = 800.0f;
    float LaneMinShare = 0.25f;
    int LaneMinUnits = 12;
    int MaxLanes = 2;
    float LaneSeparation = 1600.0f;
    // The lane's anchor stands AnchorShare of the way from our starts' centre to
    // the enemy's, on the lane, pulled toward the axis until a ground unit can reach it.
    float AnchorShare = 0.28f;
    // Layout along the lane (toward the enemy is +): nanos at NanoAlong, guns at GunAlong.
    float NanoAlong = 0.0f;
    float GunAlong = 130.0f;
    float Shake = 120.0f;                  // native looks this far round a gun or nano slot for room
    float ClusterRadius = 700.0f;          // our guns and nanos within this of the anchor belong to the lane
    float NanoSlotRadius = 250.0f;         // ... a turret only within this of one of the lane's turret slots
    int OrderBuilders = 3;                 // constructors on each live lane order (one order per kind at a time)
    // Structures, by the lane's owner only. Light gun per side (Beamer / Twin Guard /
    // Cacophony), Dragon per side (Claw / Maw / Jaw).
    dictionary LightGun = { {"armada", "armbeamer"}, {"cortex", "corhllt"}, {"legion", "legmg"} };
    dictionary DragonGun = { {"armada", "armclaw"}, {"cortex", "cormaw"}, {"legion", "legdtr"} };
    // The ladder: light guns, dragons and nanos that should stand once a step is
    // done, and the sustained (10 s minimum) incomes it needs. At least 2 nanos, at most 4.
    array<int> LadderLight = { 2, 2, 3, 4, 5, 6 };
    array<int> LadderDragon = { 0, 2, 2, 2, 2, 2 };
    array<int> LadderNano = { 2, 2, 2, 3, 3, 4 };
    array<float> LadderMetal = { 10.0f, 15.0f, 22.0f, 30.0f, 40.0f, 50.0f };
    array<float> LadderEnergy = { 100.0f, 150.0f, 250.0f, 350.0f, 500.0f, 700.0f };
    int PublishSeconds = 20;               // the owner's lanes go to the allies this often
    int OwnerWaitSeconds = 90;             // a lane nobody published this long after we saw it: we hold it ourselves
    int ReportSeconds = 120;
} }
