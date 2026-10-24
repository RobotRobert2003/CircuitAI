// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace RoleSettings {        
        // Early allocation by reachable walking distance from starting commanders.
        // At this game time, every ally may take unoccupied reachable spots.
        bool MexOwnershipEnabled = false;
        float MexOwnershipSeconds = 360.0f; // 0 disables early protection (D-352: 6 minutes, down from 10, land and water alike)
        // D-352: mex ownership by theatre. Rules in resource/MexTerritory.h; policy
        // here. Every number an ally reads comes from the roster broadcast
        // (systems/team/mex_claim.as), never from a map config.
        namespace MexClaim {
            bool TheatresEnabled = false;      // experimental_balanced switches it on
            float TheatreSeconds = -1.0f;      // sea and race-won spots: -1 the land window, 0 the whole game
            float HomeRadius = 900.0f;         // rule 1: every role owns the land spots this close to its start
            float LaneMergeRadius = 450.0f;    // lane partition: a route joins a lane this close to its spine
            float LaneMergeShare = 0.6f;       //   for this share of its cells
            float LaneBandRadius = 1200.0f;    //   a cluster this close to a spine is a lane cluster
            bool FrontLaneSpots = true;        // roles that claim lane clusters inside the window
            bool SupportLaneSpots = true;
            bool TacticalLaneSpots = false;
            bool TechLaneSpots = false;
            bool AirLaneSpots = false;
            bool SeaLaneSpots = false;
            // Securing structures per role (counts), timed with the constructor's
            // build power and the role's income: the race's secure lead.
            int AirSecureLLT = 1;  int AirSecureAA = 1;
            int TacticalSecureLLT = 1; int TacticalSecureAA = 0;
            int SeaSecureLLT = 0;  int SeaSecureAA = 0;
            float ExpectedOpeningIncome = 6.0f; // metal per second assumed while the opener runs and nothing is measured
            int ReannounceSeconds = 30;         // a readiness change smaller than this is not rebroadcast (a slow factory moves the estimate every tick)
            int ReannounceAnchor = 64;          // elmos an anchor must move to rebroadcast
            int WidgetSeconds = 10;             // territory overlay refresh check
        }
        /******************** MEX UPGRADE PRIORITY ********************/
        // A mex upgrade is the best metal-per-metal available and spots are
        // finite, so every role ranks it ahead of its energy ladder. Radius is
        // measured from the role's economy anchor; MaxConcurrent 0 disables it.
        bool MexUpgradeFirst = true;
        float MexUpgradeRadius = 2500.0f;
        int MexUpgradeMaxConcurrent = 1;

       

        // Max number of workers assigned as guards to a single leader (primary or secondary)
        // Applies to builder guard distribution logic (bots/veh/air/sea). Can be tuned per-profile.
        int BuilderMaxGuardsPerLeader = 10;

        // Max number of workers assigned as guards to a tactical constructor (per category)
        // Independent from primary/secondary caps. Default 0 disables tactical guarding.
        int BuilderMaxGuardsPerTacticalLeader = 0;

        // Shared AIR/TECH wall exclusion, measured from every allied start.
        float WallBaseExclusionRadius = 1200.0f;

        
}
}
