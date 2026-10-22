// D-296: land scout backline raids. Shared defaults; a role may override
// these before units are admitted. The feature also requires the profile JSON
// switch "scout_raid": {"enabled": true} (experimental_balanced only).
namespace Global {
namespace ScoutRaid {
        bool Enabled = true;
        // Non-spam land scouts that raid. Spam defs (Global::Spam::UnitByFactory)
        // are never admitted even if listed here.
        array<string> Units = {"armflea", "armfav", "corfav", "legscout"};
        int MaxRaiders = 6;          // per AI, concurrent
        int KeepNativeScouts = 1;    // first N listed scouts keep native CScoutTask recon
        // Observed armed-ground coverage is dilated by this margin (elmos).
        float HazardMargin = 120.0f;
        // An unidentified radar dot is avoided with this radius (a T1 turret's
        // range); identification replaces it with the contact's real range.
        float UnknownHazardRange = 700.0f;
        // Extra route cost per 64-elmo cell inside that coverage (soft avoid).
        float HazardWeight = 50.0f;
        // Target kind weights (0 disables a kind).
        float MexWeight = 3.0f;
        float NanoWeight = 4.0f;
        float WindWeight = 2.0f;
        float OtherEconomyWeight = 0.0f;
        float StandoffFraction = 0.8f;      // of weapon range from the target
        // Covered-waypoint lookahead along the issued route (elmos; at least
        // the next three waypoints). Sensor-to-tick latency is 2-3 s.
        float LookaheadElmos = 1200.0f;
        float LookaheadSeconds = 10.0f;     // or this many seconds of the def's speed, if larger
        float ChainRadius = 1500.0f;        // after a kill, prefer the next target this close
        int ReplanCooldownSeconds = 4;      // per raider
        // New-feature latency budget (D-296), not a cap on existing behaviour:
        // synchronous raid-route solves per AI per second.
        int MaxRoutesPerSecond = 2;
        int StuckSeconds = 8;
        float WaypointSpacing = 192.0f;     // minimum spacing of compacted MOVE waypoints
    }
}
