// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace Military {
        float AggressionAutoWeight = 0.25f;
        float AttackWaitSeconds = 180.0f;
        // Owner (2026-10-16): no role builds Telchines (legamph). AmphibiousOps recruits none and masks
        // them from the native chooser, TECH's land-locked batch takes the ground T2 bot instead.
        // Off here; experimental_balanced sets it and gives legamph "limit": 0 in behaviour_leg.json.
        bool NoTelchines = false;
        float AttackScale = 0.8f;
        // D-214: funded land siege before ordinary FRONT combat selection.
        // Shares limit dedicated bombardment investment, leaving a mobile screen.
        bool LandSiegeEnabled = true;
        float LandSiegeMinMetal = 40.0f;
        float LandSiegeMinEnergy = 800.0f;
        float LandSiegeFullMetal = 120.0f;
        float LandSiegeResponseRatio = 1.25f;
        float LandSiegeEarlyShare = 0.20f;
        float LandSiegeLateShare = 0.35f;
    }
}
