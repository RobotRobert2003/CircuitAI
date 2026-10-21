// Lolcannons (owner, 2026-10-21): the Ragnarok (armvulc), Calamity (corbuzz) and
// Starfall (legstarfall). Policy: systems/construction/lolcannon.as.
namespace Global {
namespace LolCannon {
    // Off by default; experimental_balanced/main.as turns it on. When on, every
    // other path to the three cannons is closed for every role (native porc
    // chain slot 21, AIR's chain, the C++ super weapon, TECH's super cluster,
    // the LRPC_HEAVY objective) and only FRONT and TECH may build one, here.
    bool Enabled = false;
    // gates, all required (10 s minimum income, as Economy::GetMin*IncomeLast10s)
    float MinMetalIncome = 400.0f;
    float MinEnergyIncome = 10000.0f;
    int MinGameSeconds = 35 * 60;
    // the construction turret block, built first (cols x rows, biggest first; 4 to 20)
    int MinTurrets = 4;
    int TurretsAtOnce = 6;     // turret orders in flight at once (the crew helps the rest)
    array<int> TurretBlocks = { 5, 4, 4, 4, 4, 3, 3, 3, 3, 2, 2, 2 };
    // advanced (hardened) energy storages, built second
    int Storages = 4;          // armuwadves, coruwadves
    int LegionStorages = 6;    // legadvestore, for the Starfall
    // the dedicated T2 constructor crew: CrewMin at the metal gate, one more per
    // CrewMetalStep of 10 s metal income above it, at most CrewMax
    int CrewMin = 7;
    int CrewMax = 15;
    float CrewMetalStep = 100.0f;
    int CrewOrderSeconds = 30;      // missing crew is re-ordered this often
    int MaxCannons = 1;             // cannons a program builds (a lost one is rebuilt)
    float SiteMinDistance = 250.0f; // search rings round the base centre, elmos
    float SiteMaxDistance = 2200.0f;
    int StallSeconds = 240;         // a phase with no work for this long moves on (refused slots)
}
}
