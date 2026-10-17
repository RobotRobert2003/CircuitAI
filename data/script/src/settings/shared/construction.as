// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace RoleSettings {        
        // Early allocation by reachable walking distance from starting commanders.
        // At this game time, every ally may take unoccupied reachable spots.
        bool MexOwnershipEnabled = false;
        float MexOwnershipSeconds = 600.0f; // 0 disables early protection
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
