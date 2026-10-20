// Idle T1 vehicle constructor reclaim (owner, 2026-10-20): barbs left battle
// wrecks on the ground for humans to take. Policy: systems/construction/idle_reclaim.as.
namespace Global {
namespace IdleReclaim {
    bool Enabled = true;
    // Constructors that take part; T1 vehicle cons by default.
    array<string> Units = { "armcv", "corcv", "legcv" };
    int MaxConcurrent = 3;             // cons on wreck runs at once, per AI
    float MaxDistance = 3500.0f;       // farthest site a con drives to (elmos)
    float AreaRadius = 350.0f;         // area-reclaim circle around a site
    float MaxSurfThreat = 0.5f;        // threat-map limit at the site centre and ring
    float MinSiteMetal = 60.0f;        // estimated wreck metal a site needs
    float WreckFraction = 0.6f;        // share of a lost unit's cost left as wreck metal
    float MinUnitCost = 20.0f;         // smaller losses are not recorded
    float SiteCell = 384.0f;           // deaths in one cell form one site
    int MaxSites = 48;
    int SiteLifetimeSeconds = 480;     // a site no death refreshed for this long is dropped
    int JobTimeoutSeconds = 60;        // a run ends after this; the con is re-asked
    int UnsafeRetrySeconds = 20;       // a site that failed the threat check waits this long
    int UnitRetrySeconds = 3;          // a con with no site is not re-scanned sooner
}
}
