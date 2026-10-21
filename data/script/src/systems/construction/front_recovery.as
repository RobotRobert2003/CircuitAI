// FRONT recovery (owner, 2026-10-19; Front::Recovery, off in src). Played (2026-10-19, AI 11, Legion
// FRONT): the base fell at 30 min, metal income dropped from +80 to +3, the rebuilt T1 vehicle plant's
// constructor ordered a T2 vehicle plant at once, and for 8 minutes after that nothing was built (pull
// 0, bank up to 800). Recovery starts once metal income falls below Front::RecoveryEnterMetalIncome
// after it had reached Front::RecoveryMinPeakMetalIncome, and ends after Front::RecoveryExitSeconds at
// or above Front::RecoveryExitMetalIncome. While it lasts: T1 constructors and the commander (when
// CommanderFront has nothing for it) retake mex spots with a safe path (nearest the start first, then
// nearest the worker), solars while energy stalls; FRONT's T2 lab/plant, nano and second-factory
// orders wait; the T1 factory makes Front::RecoveryMinT1Constructors constructors first.
namespace FrontRecovery {
    bool active = false;
    float peak = 0.0f;
    int aboveSince = -1;
    int since = -1;
    int lastLog = -100000;
    int lastMexLog = -100000;

    bool On() { return Global::RoleSettings::Front::Recovery; }
    bool Active() { return On() && active; }

    int T1Constructors() {
        return UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors())
            + UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1VehicleConstructors());
    }

    void Update(float mi) {
        if (!On()) return;
        if (!active) {
            if (mi > peak) peak = mi;
            if (peak >= Global::RoleSettings::Front::RecoveryMinPeakMetalIncome
                && mi < Global::RoleSettings::Front::RecoveryEnterMetalIncome) {
                active = true; aboveSince = -1; since = ai.frame; lastLog = ai.frame;
                GenericHelpers::LogUtil("[FRONT][Recovery] on: metal income +" + int(mi) + " (peak +" + int(peak)
                    + ") | bank " + int(aiEconomyMgr.metal.current) + " | T1 constructors " + T1Constructors(), 1);
            }
            return;
        }
        if (mi >= Global::RoleSettings::Front::RecoveryExitMetalIncome) {
            if (aboveSince < 0) aboveSince = ai.frame;
            if (ai.frame - aboveSince >= Global::RoleSettings::Front::RecoveryExitSeconds * SECOND) {
                active = false; peak = mi;
                GenericHelpers::LogUtil("[FRONT][Recovery] off after " + ((ai.frame - since) / SECOND) + " s: metal income +" + int(mi), 1);
                return;
            }
        } else aboveSince = -1;
        if (ai.frame - lastLog >= 60 * SECOND) {
            lastLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][Recovery] " + ((ai.frame - since) / SECOND) + " s: metal income +" + int(mi)
                + " | bank " + int(aiEconomyMgr.metal.current) + " | T1 constructors " + T1Constructors(), 1);
        }
    }

    // Constructors the T1 factory makes first while recovering (0 when not recovering)
    int MinT1Constructors() { return Active() ? Global::RoleSettings::Front::RecoveryMinT1Constructors : 0; }

    IUnitTask@ Work(CCircuitUnit@ u) {
        if (!Active() || u is null || u.circuitDef is null) return null;
        const bool commander = UnitHelpers::IsCommander(u.circuitDef);
        if (!commander && UnitHelpers::GetConstructorTier(u.circuitDef) != 1) return null;
        IUnitTask@ t = null;
        if (aiEconomyMgr.isEnergyStalling) {
            @t = Builder::EnqueueT1Solar(u.id, Global::AISettings::Side, u.GetPos(ai.frame), SQUARE_SIZE * 16, 60 * SECOND);
            if (t !is null) return t;
        }
        const float radius = Global::RoleSettings::Front::RecoveryMexRadius;
        @t = aiEconomyMgr.EnqueueMexWithin(u, Global::Map::StartPos, radius, 0, true);
        if (t is null) @t = aiEconomyMgr.EnqueueMexWithin(u, u.GetPos(ai.frame), radius, 0, true);
        if (t !is null && ai.frame - lastMexLog >= 20 * SECOND) {
            lastMexLog = ai.frame;
            IBuilderTask@ b = cast<IBuilderTask>(t);
            const AIFloat3 p = (b is null) ? u.GetPos(ai.frame) : b.GetBuildPos();
            GenericHelpers::LogUtil("[FRONT][Recovery] mex at " + int(p.x) + "," + int(p.z) + " by " + u.circuitDef.GetName() + " " + u.id, 1);
        }
        return t;
    }
}
