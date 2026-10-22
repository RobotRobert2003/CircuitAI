// FRONT T2 mex upgrades first (owner, 2026-10-22; Front::MexUpgradeFirst). Played: FRONT T2 constructors
// spent the mid game assisting factories and each other while most of the team's mexes stayed T1. A T2
// constructor now upgrades our T1 mexes (MexTracker, nearest first, reachable and buildable) before the
// native default work. The eco ladder's reactor orders still come first: a fusion is not held for this.
// Every Front::MexUpgradeScanSeconds a T2 constructor that only helps (factory assist/guard, patrol,
// repair, or a shared build it is not alone on, other than a mex) is moved to an open upgrade, up to
// Front::MexUpgradeMaxConcurrent upgrades at once. Allied T1 mexes stay with native: FRONT keeps the
// default MEXUP it is offered (front.as), which includes allies' spots.
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

    // The upgrade for this constructor, or null (none open, cap reached, metal full)
    IUnitTask@ Upgrade(CCircuitUnit@ u, const string &in why) {
        if (!On() || !IsT2Constructor(u) || aiEconomyMgr.isMetalFull) return null;
        CCircuitDef@ d = Moho(u);
        if (d is null || Running(d) >= Global::RoleSettings::Front::MexUpgradeMaxConcurrent) return null;
        const AIFloat3 at = Economy::MexTracker::GetNearestNonUpgradedMexInRange(u.GetPos(ai.frame), Global::Map::StartPos,
            Global::RoleSettings::Front::MexUpgradeRadius, u, d);
        if (at.x < 0.0f) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, d, at, -1));
        if (t !is null && ai.frame - lastLog >= 5 * SECOND) {
            lastLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][MexUp] " + u.circuitDef.GetName() + " " + u.id + " " + why + ": upgrading ("
                + int(at.x) + "," + int(at.z) + "), " + (Running(d)) + " running", 1);
        }
        return t;
    }

    IUnitTask@ Work(CCircuitUnit@ u) { return Upgrade(u, "asked for work"); }

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

    void Update() {
        if (!On() || ai.frame - lastScan < Global::RoleSettings::Front::MexUpgradeScanSeconds * SECOND) return;
        lastScan = ai.frame;
        array<int>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (!IsT2Constructor(u) || !Helper(u)) continue;
            IUnitTask@ up = Upgrade(u, "left a helper's job");
            if (up is null) return;   // nothing open or the cap is reached: no other helper fares better
            aiBuilderMgr.AssignTask(u, up);
        }
    }
}
