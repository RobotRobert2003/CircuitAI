// D-290: TECH's one reclaim gate (owner's rules).
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"

/******************************************************************************

TECH RECLAIM POLICY (D-290)

Every reclaim TECH's scripts order of one of our own structures asks
Allowed(target, source) first:

  never      an energy storage (owner: "a tech role should never reclaim an
             energy storage"); the native protected set (SetReclaimProtected,
             filled by ProtectEnergyStorage at init) refuses it too, so the
             native watchdog and turret joins cannot take one either
  defer      a refund that does not fit the bank: BAR pays a reclaimed
             unit's metal at completion (modrules unitMethod = 1), and metal
             past the storage cap is lost (D-072). The refund must fit:
               current + inflow + refund <= (storage - target's storage) x ReclaimBankHeadroom
             where inflow = max(0, income - pull) x ReclaimProjectionSeconds
  pause      Tick re-checks every tracked script reclaim once a second and
             aborts one whose refund stopped fitting (the bank rose while it
             ran); the target keeps its partial reclaim and its retirement,
             and the row that ordered it re-orders once the bank has room

Cost: Allowed is O(1) arithmetic plus one engine definition read. Tick is
O(tracked reclaims), a handful, once a second, with no allocation; the
tracked arrays are swap-removed. Audit is O(1) per builder task added.

******************************************************************************/
namespace TechReclaim {

    string lastSource = "";       // the source last admitted by Allowed ...
    int lastTarget = -1;          // ... for this target id (read by Audit)
    dictionary refusedLogged;     // id -> true: the energy-storage refusal is logged once per target
    dictionary deferLogged;       // id -> frame: a deferral is logged at most every 30 s per target
    // The deferred state the "should have been reclaimed by now" invariants
    // read (D-076: one owner): id -> frame the gate last deferred that target,
    // and source -> frame it last deferred any target of that path. Both O(1).
    // A deferral is current for ReclaimDeferredStaleSeconds after the last ask
    // (the rows re-ask every 3-5 s); cleared the moment the gate admits.
    dictionary deferredAt;
    dictionary deferredBySource;
    bool IsDeferred(int id)
    {
        int64 at = -100000;
        if (!deferredAt.get("" + id, at)) return false;
        return ai.frame - int(at) <= int(Global::RoleSettings::Tech::ReclaimDeferredStaleSeconds) * SECOND;
    }
    bool IsDeferredBy(const string &in source)
    {
        int64 at = -100000;
        if (!deferredBySource.get(source, at)) return false;
        return ai.frame - int(at) <= int(Global::RoleSettings::Tech::ReclaimDeferredStaleSeconds) * SECOND;
    }
    dictionary audited;           // id -> true: the audit line is written once per target

    // Script reclaims in flight, parallel arrays (swap-removed, no per-tick allocation).
    array<int> trackedIds;
    array<IUnitTask@> trackedTasks;
    array<string> trackedSources;
    array<int> overSince;         // frame the refund stopped fitting while the task lived; -1 fits

    float StorageOf(const CCircuitDef@ d)
    {
        return (d is null) ? 0.0f : aiEconomyMgr.GetMetalStorageOf(d);
    }

    // Metal paid when the reclaim completes: the full cost for a finished
    // structure (conservative for one partly reclaimed already), the built
    // share for a frame.
    float RefundOf(CCircuitUnit@ t)
    {
        if (t is null || t.circuitDef is null) return 0.0f;
        const float progress = t.GetBuildProgress();
        return t.circuitDef.costM * ((progress >= 1.0f) ? 1.0f : AiMax(0.0f, progress));
    }

    // The storage the team loses with the target (a frame adds none yet).
    float LostStorageOf(CCircuitUnit@ t)
    {
        if (t is null || t.circuitDef is null || t.GetBuildProgress() < 1.0f) return 0.0f;
        return StorageOf(t.circuitDef);
    }

    bool Fits(CCircuitUnit@ t, string &out why)
    {
        const float stor = aiEconomyMgr.metal.storage;
        const float cur = aiEconomyMgr.metal.current;
        const float refund = RefundOf(t);
        const float after = stor - LostStorageOf(t);
        float inflow = 0.0f;
        if (Global::RoleSettings::Tech::ReclaimProjectionSeconds > 0.0f)
            inflow = AiMax(0.0f, aiEconomyMgr.metal.income - aiEconomyMgr.metal.pull) * Global::RoleSettings::Tech::ReclaimProjectionSeconds;
        const float cap = after * Global::RoleSettings::Tech::ReclaimBankHeadroom;
        const bool ok = cur + inflow + refund <= cap;
        // the reason is read only on a refusal: no string is built on the common path
        why = ok ? "" : ("bank " + int(cur) + " + inflow " + int(inflow) + " + refund " + int(refund) + " > " + int(cap)
            + " (" + int(after) + " storage after x " + Global::RoleSettings::Tech::ReclaimBankHeadroom + ")");
        return ok;
    }

    bool IsEnergyStorage(CCircuitUnit@ t)
    {
        return t !is null && t.circuitDef !is null && UnitHelpers::IsEnergyStorage(t.circuitDef.GetName());
    }

    // The gate. `source` names the path for the audit line and the logs.
    bool Allowed(CCircuitUnit@ target, const string &in source)
    {
        if (target is null || target.circuitDef is null) return false;
        const string key = "" + target.id;
        if (IsEnergyStorage(target)) {
            if (!refusedLogged.exists(key)) {
                refusedLogged.set(key, true);
                GenericHelpers::LogUtil("[RECLAIM] refused " + target.circuitDef.GetName() + " " + target.id
                    + " by " + source + ": energy storage is never reclaimed (owner, D-290)", 1);
            }
            return false;
        }
        string why;
        if (!Fits(target, why)) {
            deferredAt.set(key, int64(ai.frame));
            deferredBySource.set(source, int64(ai.frame));
            int64 last = -100000;
            deferLogged.get(key, last);
            if (ai.frame - int(last) >= 30 * SECOND) {
                deferLogged.set(key, int64(ai.frame));
                GenericHelpers::LogUtil("[RECLAIM] deferred " + target.circuitDef.GetName() + " " + target.id + " by " + source + ": " + why + " (D-290)", 1);
            }
            return false;
        }
        deferredAt.delete(key);
        lastSource = source;
        lastTarget = target.id;
        return true;
    }

    // A script reclaim ordered after Allowed: watched by Tick for the pause.
    void Track(CCircuitUnit@ target, IUnitTask@ task, const string &in source)
    {
        if (target is null || task is null) return;
        for (uint i = 0; i < trackedIds.length(); ++i) {
            if (trackedIds[i] != target.id) continue;
            @trackedTasks[i] = task;
            trackedSources[i] = source;
            return;
        }
        trackedIds.insertLast(target.id);
        trackedTasks.insertLast(task);
        trackedSources.insertLast(source);
        overSince.insertLast(-1);
    }

    void Untrack(uint i)
    {
        const uint last = trackedIds.length() - 1;
        if (i != last) {
            trackedIds[i] = trackedIds[last];
            @trackedTasks[i] = trackedTasks[last];
            trackedSources[i] = trackedSources[last];
            overSince[i] = overSince[last];
        }
        trackedIds.removeLast();
        trackedTasks.removeLast();
        trackedSources.removeLast();
        overSince.removeLast();
    }

    // Once a second (TechBuild::Tick): the pause, INV-201 and INV-209.
    void Tick()
    {
        for (uint i = 0; i < trackedIds.length(); ) {
            CCircuitUnit@ t = ai.GetTeamUnit(trackedIds[i]);
            IUnitTask@ task = trackedTasks[i];
            if (t is null || task is null || task.IsDead()) { Untrack(i); continue; }
            // INV-201: no reclaim of an energy storage is ever in flight
            if (IsEnergyStorage(t))
                Invariants::Violation("INV-201", "" + t.id, "reclaim of energy storage " + t.circuitDef.GetName() + " " + t.id + " in flight (" + trackedSources[i] + ")");
            string why;
            if (Fits(t, why)) { overSince[i] = -1; ++i; continue; }
            // INV-209: the pause below must stop it; a task that outlives it this long is a violation
            if (overSince[i] < 0) overSince[i] = ai.frame;
            else if (ai.frame - overSince[i] >= int(Global::RoleSettings::Tech::InvariantReclaimOverflowSeconds) * SECOND)
                Invariants::Violation("INV-209", "" + t.id, "reclaim of " + t.circuitDef.GetName() + " " + t.id + " (" + trackedSources[i]
                    + ") still running while its refund cannot fit: " + why);
            GenericHelpers::LogUtil("[RECLAIM] paused " + t.circuitDef.GetName() + " " + t.id + " (" + trackedSources[i] + "): " + why + " (D-290)", 1);
            // The rows re-order once the bank has room; INV-008 must not count
            // turrets off a reclaim that is paused on purpose.
            const string key = "" + t.id;
            TechBuild::reclaimTargets.delete(key);
            TechBuild::turretsPulledAt.delete(key);
            aiBuilderMgr.AbortTask(task);
            if (task.IsDead()) { Untrack(i); continue; }
            ++i;
        }
    }

    // D-290 (owner): every energy storage def is reclaim-protected natively,
    // so no path (script, watchdog, turret join) can take one. Cleared on a
    // role switch (Commands), rebuilt by Tech_Init.
    void ProtectEnergyStorage()
    {
        if (!Global::RoleSettings::Tech::ReclaimProtectEnergyStorage) return;
        const array<string> names = UnitHelpers::GetAllEnergyStorages();
        int n = 0;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            aiBuilderMgr.SetReclaimProtected(d, true);
            ++n;
        }
        GenericHelpers::LogUtil("[RECLAIM] " + n + " energy storage def(s) reclaim-protected (D-290)", 1);
    }

    // D-290 audit (from Builder::AiTaskAdded, TECH): every reclaim of one of our
    // structures, once per target, naming the path, so a test can attribute it.
    void Audit(IUnitTask@ task)
    {
        IBuilderTask@ bt = cast<IBuilderTask>(task);
        if (bt is null || Task::BuildType(bt.GetBuildType()) != Task::BuildType::RECLAIM) return;
        CCircuitUnit@ target = bt.target;
        if (target is null || target.circuitDef is null || target.circuitDef.IsMobile()) return;
        if (ai.GetTeamUnit(target.id) is null) return;   // not ours (an ally's or an enemy's)
        const string key = "" + target.id;
        string source = "native";
        if (lastTarget == target.id) source = lastSource;
        else if (Invariants::constructionAdmissionRule.length() > 0) source = Invariants::constructionAdmissionRule;
        if (IsEnergyStorage(target))
            Invariants::Violation("INV-201", key, "reclaim of energy storage " + target.circuitDef.GetName() + " " + target.id + " ordered by " + source);
        string why;
        const bool fits = Fits(target, why);
        if (!fits && source != "native")
            Invariants::Violation("INV-209", key, "reclaim of " + target.circuitDef.GetName() + " " + target.id + " ordered by " + source + " overflows: " + why);
        if (audited.exists(key)) return;
        audited.set(key, true);
        GenericHelpers::LogUtil("[RECLAIM] " + target.circuitDef.GetName() + " " + target.id + " by " + source
            + " | bank " + int(aiEconomyMgr.metal.current) + "/" + int(aiEconomyMgr.metal.storage)
            + " refund " + int(RefundOf(target)) + " storage-after " + int(aiEconomyMgr.metal.storage - LostStorageOf(target))
            + (fits ? "" : " OVERFLOW"), 1);
    }
}
