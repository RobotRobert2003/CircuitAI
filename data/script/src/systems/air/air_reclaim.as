#include "../../helpers/math/production_math.as"

namespace AirReclaim {
    class Job {
        int target = -1;
        int slot = -1;
        IUnitTask@ task;
    }
    array<Job@> jobs;

    void Tick()
    {
        for (int i = int(jobs.length()) - 1; i >= 0; --i) {
            if (ai.GetTeamUnit(jobs[i].target) is null) {
                if (jobs[i].slot >= 0) aiTerrainMgr.ReleasePersistentBuilding(jobs[i].slot);
                jobs.removeAt(i);
            } else if (jobs[i].task is null || jobs[i].task.IsDead()) jobs.removeAt(i);
        }
    }
    bool Allowed(bool advanced = false)
    {
        if (MetalEconomy::Active()) {
            MetalEconomy::Read();
            return MetalEconomy::dense && AirEconomy::HasReactor() && !aiEconomyMgr.isEnergyStalling
                && MetalMath::RetirePower(AirEconomy::energy, float(jobs.length() + 1) * 75.0f,
                    aiEconomyMgr.energy.pull, MetalEconomy::goal, .1f);
        }
        if (!AirEconomy::HasReactor() || AirEconomy::recovery || aiEconomyMgr.isEnergyStalling) return false;
        const string side = Global::AISettings::Side;
        const float wind = AiMax(0.0f, AiMin(25.0f, (ai.GetWindMin() + ai.GetWindMax()) * 0.5f));
        const float t1 = AirEconomy::Count(UnitHelpers::GetWindNameForSide(side)) * wind
            + AirEconomy::Count(UnitHelpers::GetSolarNameForSide(side)) * 20.0f;
        const float adv = advanced ? AirEconomy::Count(UnitHelpers::GetAdvSolarNameForSide(side)) * 75.0f : 0.0f;
        return ProductionMath::LowTierEnergyReclaim(AirEconomy::CompletedAfus() > 0, AirEconomy::energy - t1,
            adv, aiEconomyMgr.energy.pull, advanced ? Global::RoleSettings::Tech::ReclaimAdvSolarMargin : Global::RoleSettings::Tech::ReclaimT1EnergyMargin);
    }
    IUnitTask@ MakeTask(CCircuitUnit@ worker)
    {
        Tick();
        if (worker is null || !worker.circuitDef.IsMobile() || !Allowed()
            || jobs.length() >= uint(Global::RoleSettings::Tech::ReclaimEnergyConcurrent)) return null;
        const string side = Global::AISettings::Side;
        const array<string> names = {UnitHelpers::GetWindNameForSide(side), UnitHelpers::GetSolarNameForSide(side), UnitHelpers::GetAdvSolarNameForSide(side)};
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint tier = 0; tier < names.length(); ++tier) {
            if (tier == 2 && !Allowed(true)) continue;
            CCircuitUnit@ best = null;
            float distance = Global::RoleSettings::Tech::ReclaimEnergyRadius * Global::RoleSettings::Tech::ReclaimEnergyRadius;
            for (uint i = 0; i < ids.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
                if (u is null || u.GetBuildProgress() < 1.0f || u.circuitDef.GetName() != names[tier]) continue;
                bool pending = false;
                for (uint j = 0; j < jobs.length(); ++j) if (jobs[j].target == u.id) pending = true;
                if (pending || !AirHome::EconomySite(u.GetPos(ai.frame))
                    || !aiTerrainMgr.CanReachAt(worker, u.GetPos(ai.frame), worker.circuitDef.GetBuildDistance())) continue;
                const float sq = MapHelpers::SqDist(worker.GetPos(ai.frame), u.GetPos(ai.frame));
                if (sq < distance) { @best = u; distance = sq; }
            }
            if (best is null) continue;
            IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::NORMAL, best, 120 * SECOND));
            if (task is null) continue;
            Job job; job.target = best.id; @job.task = task;
            for (uint c = 0; c < AirLayout::windClusters.length(); ++c)
                for (uint s = 0; s < AirLayout::windClusters[c].slots.length(); ++s)
                    if (aiTerrainMgr.GetReservationUnit(AirLayout::windClusters[c].slots[s]) is best)
                        job.slot = AirLayout::windClusters[c].slots[s];
            jobs.insertLast(job);
            Lifecycle::Retire(best, "AIR low-tier energy replaced by completed reactor");
            if (!AirEconomy::HasReactor()) Invariants::Violation("INV-110", "AIR", "low-tier energy reclaim without completed reactor");
            GenericHelpers::LogUtil("[AIR][Reclaim] " + names[tier] + " id=" + best.id + " worker=" + worker.id, 1);
            return task;
        }
        return null;
    }
}
