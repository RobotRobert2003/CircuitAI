// FRONT T2 mex upgrades first (owner, 2026-10-22; Front::MexUpgradeFirst). Played: FRONT T2 constructors
// spent the mid game assisting factories and each other while most of the team's mexes stayed T1. A T2
// constructor now upgrades our T1 mexes (MexTracker, nearest first, reachable and buildable) before the
// native default work. The eco ladder's reactor orders still come first: a fusion is not held for this,
// except the second fusion, which waits for our T1 mexes (Front::EcoLadderMexUpBeforeSecondFusion,
// front_eco_ladder.as MexGate).
// Every Front::MexUpgradeScanSeconds a T2 constructor that only helps (factory assist/guard, patrol,
// repair, or a shared build it is not alone on, other than a mex) is moved to an open upgrade, up to
// Front::MexUpgradeMaxConcurrent upgrades at once (Front::MexUpgradeGateConcurrent while the gate holds).
// Allied T1 mexes stay with native: FRONT keeps the default MEXUP it is offered (front.as), which
// includes allies' spots.
// No ping-pong (owner, 2026-10-27): a T2 constructor on a MEXUP is kept on it through native
// re-evaluation (Keep, from manager/builder.as AiMakeTask) for Front::MexUpgradeCommitSeconds, and the
// scan does not pull one constructor twice within Front::MexUpgradeRepullSeconds.
namespace FrontMexUp {
    int lastScan = -100000;
    int lastLog = -100000;

    bool On() { return Global::RoleSettings::Front::MexUpgradeFirst; }

    bool IsT2Constructor(CCircuitUnit@ u) {
        return u !is null && u.circuitDef !is null && u.circuitDef.IsMobile()
            && !UnitHelpers::IsCommander(u.circuitDef) && UnitHelpers::GetConstructorTier(u.circuitDef) == 2;
    }

    CCircuitDef@ Moho(CCircuitUnit@ u) {
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        if (d.maxThisUnit >= 0 && d.count >= d.maxThisUnit) return null;
        if (!u.circuitDef.CanBuild(d)) return null;
        return d;
    }

    int Running(CCircuitDef@ d) { return aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEXUP), d); }

    // The upgrade for this constructor, or null (none open, cap reached, metal full). gate: for the eco
    // ladder's mex gate (its concurrency, every order logged)
    IUnitTask@ Upgrade(CCircuitUnit@ u, const string &in why, bool gate = false) {
        if (!On() || !IsT2Constructor(u) || aiEconomyMgr.isMetalFull) return null;
        CCircuitDef@ d = Moho(u);
        const int cap = (gate || FrontEcoLadder::MexGateHolds()) ? Global::RoleSettings::Front::MexUpgradeGateConcurrent
            : Global::RoleSettings::Front::MexUpgradeMaxConcurrent;
        if (d is null || Running(d) >= cap) return null;
        const AIFloat3 at = Economy::MexTracker::GetNearestNonUpgradedMexInRange(u.GetPos(ai.frame), Global::Map::StartPos,
            Global::RoleSettings::Front::MexUpgradeRadius, u, d);
        if (at.x < 0.0f) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, d, at, -1));
        if (t !is null && (gate || ai.frame - lastLog >= 5 * SECOND)) {
            lastLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][MexUp] " + u.circuitDef.GetName() + " " + u.id + " " + why + ": upgrading ("
                + int(at.x) + "," + int(at.z) + "), " + (Running(d)) + " running", 1);
        }
        return t;
    }

    IUnitTask@ Work(CCircuitUnit@ u) { return Upgrade(u, "asked for work"); }

    // T2 constructors held on their upgrade: the MEXUP each was first seen on and when
    array<int> commitIds;
    array<IUnitTask@> commitTasks;
    array<int> commitFrames;
    int keeps = 0;          // re-evaluations answered "stay", for the log
    int keepLog = -100000;

    int CommitIndex(int id) {
        for (uint i = 0; i < commitIds.length(); ++i) if (commitIds[i] == id) return int(i);
        return -1;
    }
    void Forget(int id) {
        const int i = CommitIndex(id);
        if (i < 0) return;
        commitIds.removeAt(i); commitTasks.removeAt(i); commitFrames.removeAt(i);
    }

    // manager/builder.as AiMakeTask, before any provider: true keeps a FRONT T2 constructor on the live
    // MEXUP it holds (AiMakeTask returns null, which native's re-evaluation reads as "keep the current
    // task"). An idle constructor asking for work is not on a live MEXUP, so this never blocks new work.
    bool Keep(CCircuitUnit@ u) {
        if (!On() || Global::AISettings::Role != AiRole::FRONT || Global::RoleSettings::Front::MexUpgradeCommitSeconds <= 0
            || !IsT2Constructor(u) || LolCannon::IsCrew(u.id)) return false;
        IBuilderTask@ b = cast<IBuilderTask>(u.task);
        if (b is null || b.IsDead() || Task::BuildType(b.GetBuildType()) != Task::BuildType::MEXUP) { Forget(u.id); return false; }
        int i = CommitIndex(u.id);
        if (i < 0) {
            commitIds.insertLast(u.id); commitTasks.insertLast(u.task); commitFrames.insertLast(ai.frame);
            i = int(commitIds.length()) - 1;
        } else if (commitTasks[i] !is u.task) {
            @commitTasks[i] = u.task; commitFrames[i] = ai.frame;
        }
        // held long enough (a walk that never arrives): re-evaluation may move it again
        if (ai.frame - commitFrames[i] > Global::RoleSettings::Front::MexUpgradeCommitSeconds * SECOND) return false;
        keeps++;
        if (ai.frame - keepLog >= 30 * SECOND) {
            keepLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][MexUp] kept " + u.circuitDef.GetName() + " " + u.id + " on its upgrade at ("
                + int(b.GetBuildPos().x) + "," + int(b.GetBuildPos().z) + ") through re-evaluation (" + keeps + " so far)", 1);
        }
        return true;
    }

    // A helper: work the team loses nothing by moving (another builder stays on a shared build)
    bool Helper(CCircuitUnit@ u) {
        IUnitTask@ t = u.task;
        if (t is null || t.IsDead() || t.IsExternalControlled() || t.IsEnemyReclaim()) return false;
        if (t.GetType() != Task::Type::BUILDER) return false;
        IBuilderTask@ b = cast<IBuilderTask>(t);
        if (b is null) return false;
        const Task::BuildType bt = Task::BuildType(b.GetBuildType());
        if (bt == Task::BuildType::MEX || bt == Task::BuildType::MEXUP) return false;
        if (bt == Task::BuildType::GUARD || bt == Task::BuildType::PATROL || bt == Task::BuildType::REPAIR) return true;
        array<CCircuitUnit@>@ units = t.GetUnits();
        return units !is null && units.length() >= 2;
    }

    // The scan's last pull of each constructor (MexUpgradeRepullSeconds)
    array<int> pulledIds;
    array<int> pulledFrames;
    bool PulledRecently(int id) {
        for (uint i = 0; i < pulledIds.length(); ++i)
            if (pulledIds[i] == id) return ai.frame - pulledFrames[i] < Global::RoleSettings::Front::MexUpgradeRepullSeconds * SECOND;
        return false;
    }
    void Pulled(int id) {
        for (uint i = 0; i < pulledIds.length(); ++i) if (pulledIds[i] == id) { pulledFrames[i] = ai.frame; return; }
        pulledIds.insertLast(id); pulledFrames.insertLast(ai.frame);
    }

    void Update() {
        if (!On() || ai.frame - lastScan < Global::RoleSettings::Front::MexUpgradeScanSeconds * SECOND) return;
        lastScan = ai.frame;
        // bounded by our T2 constructors: drop the entries of dead tasks and old pulls
        for (int i = int(commitIds.length()) - 1; i >= 0; --i)
            if (commitTasks[i] is null || commitTasks[i].IsDead()) { commitIds.removeAt(i); commitTasks.removeAt(i); commitFrames.removeAt(i); }
        for (int i = int(pulledIds.length()) - 1; i >= 0; --i)
            if (ai.frame - pulledFrames[i] >= Global::RoleSettings::Front::MexUpgradeRepullSeconds * SECOND) { pulledIds.removeAt(i); pulledFrames.removeAt(i); }
        array<int>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            // the lolcannon crew is never a helper here (owner 2026-10-28: a FRONT starter
            // was pulled off its cannon order, shared with its crew, for 15 min)
            if (!IsT2Constructor(u) || LolCannon::IsCrew(u.id) || !Helper(u) || PulledRecently(u.id)) continue;
            IUnitTask@ up = Upgrade(u, "left a helper's job");
            if (up is null) return;   // nothing open or the cap is reached: no other helper fares better
            Pulled(u.id);
            aiBuilderMgr.AssignTask(u, up);
        }
    }
}
