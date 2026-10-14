namespace Global { namespace Commander {
    bool Enabled=true;
    float Scan=1000.f, HomeLeash=700.f, FrontLeash=5000.f;
    float SupportMetal=600.f, MinimumValue=180.f, KillReward=45.f;
    float HpReserve=.35f, Retreat=.45f, Recover=.8f, AggressionWeight=.25f;
    float Step=80.f, MaxApproach=180.f, MaxSeconds=12.f, AlignSeconds=.6f;
    float Shots=2.f, EnergyMargin=150.f, CloakSeconds=1.5f, EscapeSeconds=4.3f;
    float DonorReserve=1200.f, GrantLimit=4000.f, EnergyRequestSeconds=3.f, GrantSeconds=3.f;
    float FriendlyMargin=12.f, FrontWorkers=2.f;
    float FrontDistance=3200.f, FrontStandoff=650.f, FrontRadius=500.f, FrontThreat=3.f;
    float FrontRadarSpacing=500.f, FrontLaserSpacing=300.f;
    float T3Intercept=1.f, T3Health=.2f, T3Distance=1000.f, DetectionMargin=32.f;
    // D-293: fall back to the backline porc line when an enemy group of units
    // able to attack the commander (members within FallbackGroupRadius of each
    // other) is worth FallbackMetal or more within FallbackRangeScale x the
    // commander's weapon range. Profile JSON overrides these defaults; a per-AI
    // CommanderCombat::Override() overrides both.
    bool Fallback=true;
    float FallbackMetal=400.f, FallbackRangeScale=2.f, FallbackGroupRadius=400.f;
    float FallbackOffset=120.f, FallbackSearch=2000.f, FallbackHoldSeconds=3.f, FallbackPorcRange=1500.f;
    // Seconds a mobile enemy sensor lost from sight and radar still blocks a
    // concealed approach; afterwards its position is treated as unknown.
    float SensorMemory=10.f;
    // D-294: T3 engagement from the line. Leash around the engagement start,
    // seconds a HOLD target may stop closing before the commander flanks, and
    // the post-kill dodge. Per-unit plans: commander.combat.t3_profiles, or
    // CommanderCombat::Override("t3.<unit>.<approach|commit|juke|standoff|health>", v).
    float T3Leash=900.f, T3HoldSeconds=4.f, T3DodgeSeconds=1.2f, T3HuntLeash=1800.f;
    // Friendly combat metal that must be inside the T3's reach before a kill
    // needing three or more D-gun hits (it soaks the T3's guns).
    float T3Screen=300.f;
    // Short local opportunities only; a remote artillery hunt or commander
    // trade requires an explicit policy override.
    float T3Hunt=0.f, T3ArtilleryApproach=180.f, T3Trade=0.f, T3RetrySeconds=2.f;
    float T3CloakedVolleyRisk=0.25f; // future retargeting only; incoming salvos/death blasts retain full risk
    float T3BaitCount=4.f, T3BaitMargin=150.f, T3BaitDistance=120.f, T3BaitSpacing=80.f, T3BaitTimeout=5.f;
    // D-299: FRONT commander work ladder (CommanderFront::Work orders it).
    // Fallback line: one LineDefence turret per LineIncome metal income,
    // clamped to [LineMin, LineMax], counted per line (no stacking), the line
    // kept open LineHoldSeconds after the fallback ends. Timed: one LLT and one
    // light AA every TimedInterval seconds after reaching the front, until
    // TimedUntil seconds of game time. WorkRadius 0 = the commander's LOS.
    bool Work=true;
    float LineIncome=20.f, LineMin=1.f, LineMax=6.f, LineRadius=400.f, LineSpacing=80.f;
    float LineHoldSeconds=60.f, LineRetrySeconds=5.f;
    float TimedInterval=30.f, TimedUntil=300.f;
    float WorkRadius=0.f, WorkClearance=400.f, RepairHealth=.98f;
    float ReclaimStorage=.95f, ReclaimMetal=1.f, RadarCoverage=.8f, BaseRadius=1500.f;
} }
