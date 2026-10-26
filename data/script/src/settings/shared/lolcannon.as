// Lolcannons (owner, 2026-10-21; reworked 2026-10-26): the Ragnarok (armvulc),
// Calamity (corbuzz) and Starfall (legstarfall). Policy: systems/construction/lolcannon.as.
namespace Global {
namespace LolCannon {
    // Off by default; experimental_balanced/main.as turns it on. When on, every
    // other path to the three cannons is closed for every role (native porc
    // chain slot 21, AIR's chain, the C++ super weapon, TECH's super cluster,
    // the LRPC_HEAVY objective) and only FRONT and TECH may build one, here.
    bool Enabled = false;
    // gates, all required (10 s minimum income, as Economy::GetMin*IncomeLast10s).
    // One cannon per entry of MetalIncomeGates: the first at 600 metal/s, the
    // second at 1000. A lost cannon is rebuilt on its own site.
    array<float> MetalIncomeGates = { 600.0f, 1000.0f };
    float MinEnergyIncome = 5000.0f;
    int MinGameSeconds = 0;
    // the site: on a ring round an enemy start, just inside the cannon's range
    // (range - SiteRangeMarginMax .. range - SiteRangeMarginMin), the candidate
    // nearest our base first. The ground must score SiteMinScore (flat x
    // buildable, TECH's layout measure) over the cannon, its turret block and
    // its storage strip, and hold the cannon's footprint and MinTurrets turrets.
    float SiteRangeMarginMin = 150.0f;
    float SiteRangeMarginMax = 650.0f;
    float SiteRangeStep = 125.0f;
    int SiteAngles = 64;            // candidates per ring
    int SiteProbes = 40;            // candidates whose footprint is actually tried, nearest our base first
    float SiteMinScore = 0.7f;
    // the construction turret block beside the cannon (cols x rows, across x along)
    int TurretCols = 4;
    int TurretRows = 4;
    int MinTurrets = 16;
    int TurretsAtOnce = 8;          // turret orders in flight at once (the crew helps the rest)
    // advanced (hardened) energy storages, in a narrow strip two wide on the
    // other side of the cannon (armuwadves / coruwadves; legadvestore for the Starfall)
    int Storages = 6;
    int LegionStorages = 8;
    int StorageCols = 2;
    // the crews. One T2 air constructor orders the cannon; AirCrew air
    // constructors (T1 or T2) are taken off every other task, build the
    // turret block and then assist the cannon; StoreCrew T2 air constructors
    // build the storages, then assist. Our own air constructors are claimed
    // first, the rest ordered from our air plants (CrewRecruitBatch a round).
    // With no air plant that can make them, T2 ground constructors stand in.
    int AirCrew = 50;
    int StoreCrew = 5;
    int CrewRecruitBatch = 10;
    int CrewOrderSeconds = 20;      // claims and recruit orders this often
    int StallSeconds = 240;         // turrets/storages with no work this long: the cannon is ordered anyway
    // firing: only the roster below, best tier first (CSuperTask::SetTargetTier),
    // fire held otherwise so the engine never spends it on spam
    bool FireTiers = true;
    int FireRetargetFrames = 60;
    // when a cannon stands, AIR flies one scout sweep of this make-up
    int ReconT1Scouts = 10;
    int ReconRadarScouts = 3;
}
}
