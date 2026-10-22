// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace Ferry {
        float DropPullback = 300.0f;
        float SafeDropRadius = 900.0f;
        float DropSurfaceThreat = 1.0f;
        float DropAirThreat = 1.0f;
        int AwaitTransportSeconds = 120;
        float ParkDistance = 450.0f;      // D-112: gifts wait this far behind our start (away from the map centre)
        float ParkSpacing = 80.0f;        // D-112: gifts park this far apart
        int ParkWaitSeconds = 900;        // D-112: a gift's park (renewed at every ask)
        int FerryUnloadSeconds = 15;      // D-122: INV-052: a run unloads within this
        float GiveNearDrop = 800.0f;      // D-112: a failed run gives its cargo only within this of the drop
        int FerryRunAttempts = 2;         // D-112: flown runs tried for one gift before it walks     // D-110: the drop point is this far short of the teammate's start, toward our base (open ground)
        bool Enabled = true;
        // The light transports. They carry one unit of transportsize <= 3
        // and mass <= 750; a T2 constructor is 2x2 and, because the engine
        // defaults a unit's mass to its metal cost when the def sets none
        // (Recoil UnitDef.cpp: GetFloat("mass", cost.metal)), weighs 410-470.
        // The heavy ones (armhvytrans / corhvytrans / legatrans) lift more but
        // cost 190 against 68-74, and the ferry never carries anything the
        // light one cannot. All six come from the T1 air plant.
        dictionary HeavyTransportBySide = {{"armada", "armhvytrans"}, {"cortex", "corhvytrans"}, {"legion", "legatrans"}};
        array<string> LightTransportDefs = {"armatlas", "corvalk", "leglts"};
        array<string> HeavyTransportDefs = {"armhvytrans", "corhvytrans", "legatrans"};
        dictionary TransportBySide = {
            {"armada", "armatlas"},
            {"cortex", "corvalk"},
            {"legion", "leglts"}
        };
        // Every transport def the ferry could be asked to build. They are all
        // capped at 0 for every role, and AIR raises the one it owes to
        // owned+1 only while a request is open. Without the cap the native
        // recruiter treats a transport with a role entry as ordinary air
        // production and builds extras that idle with nothing to carry.
        array<string> AllTransportDefs = {
            "armatlas", "corvalk", "leglts",
            "armhvytrans", "corhvytrans", "legatrans"
        };
        // When TECH asks on its own: sliding-minimum metal income it must
        // clear while owning no transport. Not tied to the T2 lab - that
        // trigger fired on the lab being *planned* and delivered far too early.
        float RequestMinMetalIncome = 20.0f;
        // A requester waits this long before asking again (transport died,
        // or AIR was busy serving someone else).
        float RequestCooldownSeconds = 180.0f;
        // How close the transport must get to the requester's base before AIR
        // hands ownership across.
        float ArriveRadius = 320.0f;
        // How long one transport order is allowed to produce nothing before
        // AIR orders another. Only a safety net: the normal path clears the
        // latch the moment the unit appears.
        float OrderTimeoutSeconds = 120.0f;
    }
}
