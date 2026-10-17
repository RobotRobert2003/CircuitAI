// FRONT (owner, 2026-10-16): once a fusion stands, FRONT reclaims its winds, solars and
// advanced solars, those closest to its factories first. Played (2026-10-16): FRONT #12 boxed
// several Fatboys in with advanced solars and winds round its labs; they could not leave to fight.
// Modelled on AirReclaim / TECH D-077: winds and solars once energy income without them covers the
// pull by Front::ReclaimT1EnergyMargin, advanced solars at Front::ReclaimAdvSolarMargin (or as soon
// as an advanced fusion stands). Off unless the profile sets Front::ReclaimT1EnergyAfterFusion
// (experimental_balanced/main.as).
#include "../../helpers/math/production_math.as"
namespace FrontReclaim {
    array<int> targets;          // structures being reclaimed
    array<IUnitTask@> tasks;

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
        if (!ProductionMath::LowTierEnergyReclaim(afus, income, t1, pull, Global::RoleSettings::Front::ReclaimT1EnergyMargin)) return 0;
        return ProductionMath::LowTierEnergyReclaim(afus, income - t1, adv, pull, Global::RoleSettings::Front::ReclaimAdvSolarMargin) ? 2 : 1;
    }
    IUnitTask@ Work(CCircuitUnit@ worker)
    {
        if (!Global::RoleSettings::Front::ReclaimT1EnergyAfterFusion || worker is null || worker.circuitDef is null
            || !worker.circuitDef.IsMobile() || UnitHelpers::IsCommander(worker.circuitDef)) return null;
        Tick();
        if (targets.length() >= uint(Global::RoleSettings::Front::ReclaimEnergyConcurrent)) return null;
        const int level = Level();
        if (level == 0) return null;
        const string side = Global::AISettings::Side;
        const string wind = UnitHelpers::GetWindNameForSide(side);
        const string solar = UnitHelpers::GetSolarNameForSide(side);
        const string advSolar = UnitHelpers::GetAdvSolarNameForSide(side);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        array<AIFloat3> labs;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.circuitDef !is null && IsFactoryName(u.circuitDef.GetName())) labs.insertLast(u.GetPos(ai.frame));
        }
        const AIFloat3 wp = worker.GetPos(ai.frame);
        const float nearLab = Global::RoleSettings::Front::ReclaimNearFactoryRadius;
        const float reach = Global::RoleSettings::Front::ReclaimEnergyRadius;
        CCircuitUnit@ best = null;
        float bestScore = 1e30f;
        bool bestNearLab = false;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null || u.GetBuildProgress() < 1.0f) continue;
            const string n = u.circuitDef.GetName();
            if (n != wind && n != solar && !(level == 2 && n == advSolar)) continue;
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
        Lifecycle::Retire(best, "FRONT low-tier energy replaced by a fusion");
        GenericHelpers::LogUtil("[FRONT][Reclaim] " + best.circuitDef.GetName() + " id=" + best.id + (bestNearLab ? " beside a factory" : "")
            + " by " + worker.circuitDef.GetName() + " " + worker.id + " | E +" + int(aiEconomyMgr.energy.income) + " pull " + int(aiEconomyMgr.energy.pull)
            + (level == 2 ? " (advanced solars too)" : ""), 1);
        return task;
    }
}
