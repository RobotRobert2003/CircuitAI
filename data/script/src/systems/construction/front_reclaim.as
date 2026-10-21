// FRONT (owner, 2026-10-16): once a fusion stands, FRONT reclaims its winds, solars and
// advanced solars, those closest to its factories first. Played (2026-10-16): FRONT #12 boxed
// several Fatboys in with advanced solars and winds round its labs; they could not leave to fight.
// Modelled on AirReclaim / TECH D-077: winds and solars once energy income without them covers the
// pull by Front::ReclaimT1EnergyMargin, advanced solars at Front::ReclaimAdvSolarMargin (or as soon
// as an advanced fusion stands). Off unless the profile sets Front::ReclaimT1EnergyAfterFusion
// (experimental_balanced/main.as).
// SUPPORT (owner, 2026-10-16): the same reclaim for SUPPORT's builders, with its own
// Support::ReclaimT1EnergyAfterFusion and Support::Reclaim* (SupportBuild::MakeTask). The settings
// below are read for the AI's current role; log [SUPPORT][Reclaim]. While SUPPORT reclaims,
// EnergyAllowed() keeps its eco planner from ordering the same winds and solars again.
// FRONT eco ladder (owner, 2026-10-16; Front::EcoLadder, systems/construction/front_eco_ladder.as):
// T1 converters come down too once the first fusion stands (owner, 2026-10-17), and the fusions once the second
// advanced fusion is framed, one at a time, when the bank has room for the refund (BAR pays it at
// completion; metal past storage is lost) and energy income without the fusion covers the pull by
// Front::EcoLadderFusionReclaimMargin (always once the second advanced fusion stands).
#include "../../helpers/math/production_math.as"
#include "front_eco_ladder.as"
namespace FrontReclaim {
    array<int> targets;          // structures being reclaimed
    array<IUnitTask@> tasks;

    bool IsSupport() { return Global::AISettings::Role == AiRole::SUPPORT; }
    bool Enabled() { return IsSupport() ? Global::RoleSettings::Support::ReclaimT1EnergyAfterFusion : Global::RoleSettings::Front::ReclaimT1EnergyAfterFusion; }
    float T1Margin() { return IsSupport() ? Global::RoleSettings::Support::ReclaimT1EnergyMargin : Global::RoleSettings::Front::ReclaimT1EnergyMargin; }
    float AdvSolarMargin() { return IsSupport() ? Global::RoleSettings::Support::ReclaimAdvSolarMargin : Global::RoleSettings::Front::ReclaimAdvSolarMargin; }
    float NearFactoryRadius() { return IsSupport() ? Global::RoleSettings::Support::ReclaimNearFactoryRadius : Global::RoleSettings::Front::ReclaimNearFactoryRadius; }
    float EnergyRadius() { return IsSupport() ? Global::RoleSettings::Support::ReclaimEnergyRadius : Global::RoleSettings::Front::ReclaimEnergyRadius; }
    int Concurrent() { return IsSupport() ? Global::RoleSettings::Support::ReclaimEnergyConcurrent : Global::RoleSettings::Front::ReclaimEnergyConcurrent; }
    string Tag() { return IsSupport() ? "SUPPORT" : "FRONT"; }

    void Tick()
    {
        for (int i = int(targets.length()) - 1; i >= 0; --i) {
            if (ai.GetTeamUnit(targets[i]) is null || tasks[i] is null || tasks[i].IsDead()) {
                targets.removeAt(i); tasks.removeAt(i);
            }
        }
    }
    bool IsFactoryName(const string &in n)
    {
        return UnitHelpers::IsT1BotLab(n) || UnitHelpers::IsT2BotLab(n) || UnitHelpers::IsT1VehicleLab(n)
            || UnitHelpers::IsT2VehicleLab(n) || n == "armshltx" || n == "corgant" || n == "leggant";
    }
    int Count(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        return d is null ? 0 : AiMax(0, d.count - aiBuilderMgr.GetUnfinishedCount(d));
    }
    // 0 = not allowed, 1 = winds and solars, 2 = advanced solars too
    int Level()
    {
        if (aiEconomyMgr.isEnergyStalling) return 0;
        const string side = Global::AISettings::Side;
        const bool afus = Count(UnitHelpers::GetAdvFusionNameForSide(side)) > 0;
        if (!afus && Count(UnitHelpers::GetFusionNameForSide(side)) < 1) return 0;
        const float wind = AiMax(0.0f, AiMin(25.0f, (ai.GetWindMin() + ai.GetWindMax()) * 0.5f));
        const float t1 = Count(UnitHelpers::GetWindNameForSide(side)) * wind + Count(UnitHelpers::GetSolarNameForSide(side)) * 20.0f;
        const float adv = Count(UnitHelpers::GetAdvSolarNameForSide(side)) * 75.0f;
        const float income = aiEconomyMgr.energy.income;
        const float pull = aiEconomyMgr.energy.pull;
        if (!ProductionMath::LowTierEnergyReclaim(afus, income, t1, pull, T1Margin())) return 0;
        return ProductionMath::LowTierEnergyReclaim(afus, income - t1, adv, pull, AdvSolarMargin()) ? 2 : 1;
    }
    // Global::energyAllowed for SUPPORT while the reclaim is on: no wind or solar while they are
    // coming down, no advanced solar once those are too (energy defs only; everything else allowed).
    bool EnergyAllowed(const string &in name)
    {
        if (!Enabled()) return true;
        const string side = Global::AISettings::Side;
        const bool t1 = name == UnitHelpers::GetWindNameForSide(side) || name == UnitHelpers::GetSolarNameForSide(side);
        const bool adv = name == UnitHelpers::GetAdvSolarNameForSide(side);
        if (!t1 && !adv) return true;
        const int level = Level();
        return !(t1 && level >= 1) && !(adv && level == 2);
    }
    // A fusion at a time; its refund must fit the bank unless the storage never could hold it and
    // the ladder has built its metal storages
    int fusionLog = -100000;
    bool FusionsAllowed()
    {
        if (IsSupport() || !FrontEcoLadder::ReclaimFusions() || aiEconomyMgr.isEnergyStalling) return false;
        const string fus = UnitHelpers::GetFusionNameForSide(Global::AISettings::Side);
        for (uint i = 0; i < targets.length(); ++i) {
            CCircuitUnit@ t = ai.GetTeamUnit(targets[i]);
            if (t !is null && t.circuitDef !is null && t.circuitDef.GetName() == fus) return false;
        }
        CCircuitDef@ d = ai.GetCircuitDef(fus);
        if (d is null) return false;
        const float fusOut = FrontEcoLadder::FusionOutput(fus);
        if (!ProductionMath::LowTierEnergyReclaim(FrontEcoLadder::SecondAdvFusionStands(), aiEconomyMgr.energy.income, fusOut,
            aiEconomyMgr.energy.pull, Global::RoleSettings::Front::EcoLadderFusionReclaimMargin)) return false;
        const float bank = aiEconomyMgr.metal.current, storage = aiEconomyMgr.metal.storage;
        const bool fits = bank + d.costM <= storage;
        const bool never = storage < d.costM && FrontEcoLadder::StoragesDone();
        if (!fits && !never) {
            if (ai.frame - fusionLog >= 30 * SECOND) {
                fusionLog = ai.frame;
                GenericHelpers::LogUtil("[FRONT][Reclaim] fusion waits: refund " + int(d.costM) + " does not fit the bank " + int(bank) + "/" + int(storage), 1);
            }
            return false;
        }
        return true;
    }

    IUnitTask@ Work(CCircuitUnit@ worker)
    {
        if (!Enabled() || worker is null || worker.circuitDef is null
            || !worker.circuitDef.IsMobile() || UnitHelpers::IsCommander(worker.circuitDef)) return null;
        Tick();
        if (targets.length() >= uint(Concurrent())) return null;
        const int level = Level();
        const bool t1Conv = !IsSupport() && FrontEcoLadder::ReclaimT1Converters() && !aiEconomyMgr.isEnergyStalling;
        const bool fusions = FusionsAllowed();
        if (level == 0 && !t1Conv && !fusions) return null;
        const string side = Global::AISettings::Side;
        const string wind = UnitHelpers::GetWindNameForSide(side);
        const string solar = UnitHelpers::GetSolarNameForSide(side);
        const string advSolar = UnitHelpers::GetAdvSolarNameForSide(side);
        const string converter = UnitHelpers::GetEnergyConverterNameForSide(side);
        const string fusion = UnitHelpers::GetFusionNameForSide(side);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        array<AIFloat3> labs;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.circuitDef !is null && IsFactoryName(u.circuitDef.GetName())) labs.insertLast(u.GetPos(ai.frame));
        }
        const AIFloat3 wp = worker.GetPos(ai.frame);
        const float nearLab = NearFactoryRadius();
        const float reach = EnergyRadius();
        CCircuitUnit@ best = null;
        float bestScore = 1e30f;
        bool bestNearLab = false;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null || u.GetBuildProgress() < 1.0f) continue;
            const string n = u.circuitDef.GetName();
            const bool lowTier = level >= 1 && (n == wind || n == solar || (level == 2 && n == advSolar));
            if (!lowTier && !(t1Conv && n == converter) && !(fusions && n == fusion)) continue;
            if (targets.find(u.id) >= 0 || Lifecycle::IsRetiring(u)) continue;
            const AIFloat3 p = u.GetPos(ai.frame);
            const float toWorker = MapHelpers::SqDist(wp, p);
            if (toWorker > reach * reach) continue;
            float toLab = 1e30f;
            for (uint l = 0; l < labs.length(); ++l) toLab = AiMin(toLab, MapHelpers::SqDist(labs[l], p));
            const bool near = toLab <= nearLab * nearLab;
            // structures round the factories first (they box units in), then the nearest to the worker
            const float score = near ? toLab : toWorker;
            if (best !is null && bestNearLab && !near) continue;
            if (best is null || (near && !bestNearLab) || score < bestScore) { @best = u; bestScore = score; bestNearLab = near; }
        }
        if (best is null || !aiTerrainMgr.CanReachAt(worker, best.GetPos(ai.frame), worker.circuitDef.GetBuildDistance())) return null;
        IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::NORMAL, best, 120 * SECOND));
        if (task is null) return null;
        targets.insertLast(best.id);
        tasks.insertLast(task);
        const string bestName = best.circuitDef.GetName();
        Lifecycle::Retire(best, Tag() + (bestName == fusion ? " fusion replaced by advanced fusions"
            : bestName == converter ? " T1 converter replaced by T2 converters" : " low-tier energy replaced by a fusion"));
        GenericHelpers::LogUtil("[" + Tag() + "][Reclaim] " + bestName + " id=" + best.id + (bestNearLab ? " beside a factory" : "")
            + " by " + worker.circuitDef.GetName() + " " + worker.id + " | E +" + int(aiEconomyMgr.energy.income) + " pull " + int(aiEconomyMgr.energy.pull)
            + (level == 2 ? " (advanced solars too)" : ""), 1);
        return task;
    }
}
