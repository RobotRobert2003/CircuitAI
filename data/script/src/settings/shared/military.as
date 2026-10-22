// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace Military {
        float AggressionAutoWeight = 0.25f;
        float AttackWaitSeconds = 180.0f;
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
