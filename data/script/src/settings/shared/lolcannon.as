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
    // One cannon per entry of the role's gates, then one more every step metal/s
    // past the last of them (0: none). Owner 2026-10-27: TECH at 600, 680, 760, ...;
    // FRONT at 500, 1000, 1500, ... A lost cannon is rebuilt on its own site.
    array<float> MetalIncomeGates = { 600.0f };          // TECH
    float ExtraCannonMetalStep = 80.0f;                  // TECH
    array<float> FrontMetalIncomeGates = { 500.0f };
    float FrontExtraCannonMetalStep = 500.0f;
    int MaxCannons = 0;                                  // a cap on the count, 0 none
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
    int SiteProbes = 96;            // candidates whose footprint is actually tried, nearest our base first, out of the
                                    // 4 x SiteProbes nearest; ones whose cannon footprint sits on a metal/geo spot or
                                    // an ally layout, reservation or structure are skipped before they count
    float SiteMinScore = 0.7f;
    // further back (owner 2026-10-27): every BackOffAfter failures for one cannon (a site
    // search that found nothing, or a cannon order that came to nothing) move the rings
    // SiteBackStep further out from the enemy start, past the cannon's reach if need be,
    // at most SiteBackLevels times. A cannon order that keeps failing moves the site at once.
    int BackOffAfter = 3;
    int GunMinTrySeconds = 30;      // cannon orders with no frame count one failure per this long (a quick handover alone does not)
    float SiteBackStep = 500.0f;
    int SiteBackLevels = 6;
    // a site the cannon moved back from is not tried again (nor anything this near it)
    // for that cannon; a search that finds nothing at the last level starts over from level 0
    float SiteAvoidRadius = 400.0f;
    // the construction turret block beside the cannon (cols x rows, across x along).
    // A site must hold MinTurrets; Turrets are built, out of the block and its spare
    // rows (owner 2026-10-27: 16 + 6 for a margin of error; the gate stays at 16)
    int TurretCols = 4;
    int TurretRows = 4;
    int MinTurrets = 16;
    int Turrets = 22;
    // spare rows round the block, tried after the middle ones (centre out): a
    // site holds when any MinTurrets of the (rows + spare) x cols slots reserve
    int TurretSpareRows = 2;
    int TurretsAtOnce = 8;          // turret orders in flight at once (the crew helps the rest)
    // advanced (hardened) energy storages, in a narrow strip two wide on the
    // other side of the cannon (armuwadves / coruwadves; legadvestore for the Starfall)
    int Storages = 7;               // owner 2026-10-27: + 1 for a margin of error
    int LegionStorages = 9;
    int StorageCols = 2;
    // spare rows round the strip; the storages never gate the site: the ones
    // that do not reserve are ordered at their spots unpinned
    int StorageSpareRows = 2;
    // storages still short when the cannon stands: the starter and storage crew
    // stay on them up to this long before every crew is released (0: release at once)
    int StoreFinishSeconds = 300;
    // a storage slot that does not reserve, or whose orders keep coming to nothing,
    // moves to the nearest free spot within this of the strip's centre
    float StoreSearchRadius = 400.0f;
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
    int StarterGraceSeconds = 60;   // no T2 air constructor by then: our own T2 ground constructors may start the cannon
    int StallSeconds = 240;         // turrets/storages with no work this long: the cannon is ordered anyway
    // firing: only the roster below, best tier first (CSuperTask::SetTargetTier),
    // the engine's own targeting otherwise (FireState)
    bool FireTiers = true;
    int FireState = 2;              // owner 2026-10-26: fire at will (0 hold, 1 return, 2 fire at will)
    int FireRetargetFrames = 60;
    // areas (owner 2026-10-27): roster targets in range grouped round the best one
    // left; an area ranks by its best tier, then its roster metal. Ragnarok and
    // Calamity fire at the top GunAreas in turn, GunAreaSeconds each; the Starfall
    // at the top StarfallAreas, StarfallShotsPerArea shots each; then the top again.
    // Scouting that changes the top area sends the gun back to it at once.
    float AreaRadius = 300.0f;
    int GunAreas = 6;
    int GunAreaSeconds = 20;
    int StarfallAreas = 3;
    int StarfallShotsPerArea = 2;
    // scouting (owner 2026-10-27): at the first strike, then every ReScoutSeconds at
    // the gun's highest-rated area, AIR (TECH with no AIR on the map) flies this
    // package, spread over ReconSpread round the area and on to the far map edge
    int ReconT1Scouts = 10;
    int ReconRadarScouts = 3;
    float ReconSpread = 600.0f;
    int ReScoutSeconds = 120;
    // and at once (no more often than ReScoutMinSeconds) when the top area moves
    // further than ReconSpread from where the last package went
    int ReScoutMinSeconds = 60;
    // a cannon standing this long with no roster target in range (no strike, so no
    // first package) has the enemy spawn it was sited against scouted instead
    int BlindScoutSeconds = 60;
}
}
