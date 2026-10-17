// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace Spam {
        bool Enabled = true;
        // D-216: dedicated pressure uses mature, sustained income, while
        // ordinary early raiding stays role-owned. These defaults are tuning,
        // not a required fusion building or a universal PvP timing. A full
        // metal bank admits one pump at FloatMetalIncome (donations included),
        // but never bypasses the energy gate. See doc/spam-routes.md.
        float MinMetalIncome = 60.0f;
        float FloatMetalIncome = 30.0f;
        float MinMetalBank = 1000.0f;
        float LabMetalStep = 100.0f;
        int MaxLabs = 6;
        uint MinWorkers = 4;  // commander plus at least three workers before conversion
        // A start the land army cannot leave (Global::Map::LandLocked, from the
        // map config's start spots) never spams: the units would walk to the
        // shore and stand there. TECH on Tundra Continents was making Grunts
        // for nothing (D-052). True lets such a start spam anyway.
        bool AllowLandLocked = false;
        float MinEnergyIncome = 1500.0f;
        // ... and either falling under this fraction of its threshold deactivates
        float ReleaseFraction = 0.7f;
        // Destination lies this far past the focus along our line of approach
        float BehindEnemyDistance = 2500.0f;
        // Sideways offset between the lanes of different factories
        float LaneSpacing = 900.0f;
        // Within one factory's line: units are dealt lanes 0, +1, -1, +2, -2 ...
        // up to UnitLanes, offset UnitLaneSpacing apart, so the stream is a
        // band rather than a single file. EndSpread scales that offset at the
        // final waypoint - 0 converges every lane on the same endpoint, 1 keeps
        // full width; the run is aimed at one backline, so keep it small.
        int UnitLanes = 5;
        float UnitLaneSpacing = 160.0f;
        float EndSpread = 0.35f;
        // Waypoints stay this far from the map edge
        float MapMargin = 200.0f;
        // Rebuild every lane when the AI's combat focus moves further than
        // this. Small enough to follow a front that is actually shifting,
        // large enough that a squad shuffling in place does not re-issue
        // orders to every spam unit on the map.
        float FrontMoveThreshold = 1200.0f;
        // Rotate the focus to the next enemy start spot this often
        int RefocusMinutes = 6;
        // Which unit each T1 factory spams; factories not listed keep their role logic
        // Edge lanes (owner, 2026-10-17; systems/combat/edge_lanes.as): two FRONTs
        // each build one spam lab (2 construction turrets behind it, turrets
        // first) whose units run one side edge of the map: the edge at
        // EdgeFirstShare of the way from our starts to the enemy's, the same
        // edge at EdgeSecondShare, then the far corner on that side. Points
        // stay EdgeMargin inside the map and in the unit's movement area.
        bool EdgeLanesEnabled = false;
        float EdgeFirstShare = 0.33f;
        float EdgeSecondShare = 0.67f;
        float EdgeMargin = 200.0f;
        // owner, 2026-10-17: start once a T2 factory stands and 65 metal income held 10 s
        bool EdgeNeedsT2Factory = true;
        float EdgeMinMetalIncome = 65.0f;    // build and spam from this sustained income
        float EdgeMinEnergyIncome = 500.0f;  // ... and this (ReleaseFraction pauses it)
        bool EdgeVehicleLab = false;         // false: a T1 bot lab; true: a T1 vehicle plant
        int EdgeUnitLanes = 3;               // a narrow band along the edge
        float EdgeUnitLaneSpacing = 96.0f;
        dictionary UnitByFactory = {
            {"armlab", "armpw"},   {"corlab", "corak"},    {"leglab", "leggob"},
            {"armvp", "armflash"}, {"corvp", "corgator"},  {"legvp", "leghades"}
            // Hover plants are deliberately absent: hovers are wanted as
            // ordinary combat units all game (D-038), so armsh/corsh/legsh no
            // longer carry the spam attribute either.
        };
    }
}
