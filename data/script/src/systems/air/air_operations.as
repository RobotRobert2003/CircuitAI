#include "air_escort_scout.as"
// AIR-only ownership shared by T1 raids, advanced strikes and defensive sorties.
// Store IDs, never long-lived non-owning unit handles.
namespace AirOperations {
    array<string> groundHeavyDefs;
    bool rosterReady = false;
    array<CAirWaveTask@> operations;
    array<bool> offensive;
    // D-291, parallel to operations: the immutable bomber IDs at launch, and
    // whether the operation was ever seen ATTACKING (departed from assembly).
    array<array<int>@> launched;
    array<bool> struck;
    dictionary escorts; // unit ID -> owning wave (kept until the last bomber dies)
    dictionary bombers; // all live cohorts, not only AirWaves' newest operation
    void TrackBombers(IUnitTask@ owner, const dictionary &in cohort) {
        array<string>@ ids = cohort.getKeys();
        const int op = operations.findByRef(cast<CAirWaveTask>(owner));
        for (uint i = 0; i < ids.length(); ++i) {
            bombers.set(ids[i], @owner);
            if (op >= 0) launched[op].insertLast(parseInt(ids[i]));
        }
    }
    int BomberCount(const string &in name) {
        int count = 0;
        array<string>@ ids = bombers.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            IUnitTask@ owner;
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (!bombers.get(ids[i], @owner) || owner is null || owner.IsDead() || u is null || u.task !is owner)
                bombers.delete(ids[i]);
            else if (u.circuitDef.GetName() == name) ++count;
        }
        return count;
    }
    bool CanEscort(CCircuitUnit@ u) {
        return u !is null && u.GetBuildProgress() >= 1.0f && AirScreen::IsFighter(u.circuitDef)
            && !Committed(u.id) && (u.task is null || (u.task.GetType() != int(Task::Type::PLAYER)
                && u.task.GetType() != int(Task::Type::RETREAT) && !u.task.IsExternalControlled()));
    }
    float AvailableFighters(bool value = false) {
        // Admission and transfer share this predicate. A fighter covering a
        // ground incident is absent from the wall ledger, but still available
        // to escort. One linear census per planning attempt, no order emission.
        float result = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (CanEscort(u)) result += value ? u.circuitDef.costM : 1.0f;
        }
        return result;
    }
    bool Committed(int id)
    {
        IUnitTask@ task;
        const string key = "" + id;
        if (!escorts.get(key, @task)) return false;
        if (task !is null && !task.IsDead()) return true;
        escorts.delete(key);
        return false;
    }
    int AttachFighters(CAirWaveTask@ wave, bool attack = true)
    {
        operations.insertLast(wave); offensive.insertLast(attack);
        launched.insertLast(array<int>()); struck.insertLast(false);
        return AttachAvailableFighters(wave);
    }
    // Shared ownership for bomber operations and defensive naval relief. The
    // caller owns route/lead geometry and ends its task when the mission ends.
    int AttachAvailableFighters(IUnitTask@ owner)
    {
        if (owner is null || owner.IsDead()) return 0;
        int count = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (!CanEscort(u)) continue;
            // Transfer only this member; aborting a shared wall task steals its neighbours.
            if (!aiMilitaryMgr.TransferUnit(u, owner)) continue;
            const string key = "" + u.id;
            escorts.set(key, @owner);
            u.SetIdleMode(0); u.SetFireState(2);
            AirProduction::home.delete(key); AirScreen::Removed(u.id);
            AirWaves::heldFighters.delete(key);
            ++count;
        }
        return count;
    }
    void InitHeavyRoster()
    {
        if (!rosterReady) {
            rosterReady = true;
            const array<string> gantries = UnitHelpers::GetAllGantries();
            const array<string> factories = UnitHelpers::GetAllLabs();
            for (int id = 1; id <= ai.GetDefCount(); ++id) {
                CCircuitDef@ def = ai.GetCircuitDef(id);
                if (def is null || !def.IsMobile() || def.IsAbleToFly()) continue;
                // A gantry may also offer lower-tier units (leggantuw builds
                // the T2 Telchine). Only gantry-exclusive outputs qualify for
                // expensive defensive bomber sorties; do not redefine their
                // shared UnitDef roles or other roles' targeting.
                bool lowerTier = false;
                for (uint f = 0; f < factories.length(); ++f) {
                    if (gantries.find(factories[f]) >= 0) continue;
                    CCircuitDef@ factory = ai.GetCircuitDef(factories[f]);
                    if (factory !is null && factory.CanBuild(def)) { lowerTier = true; break; }
                }
                if (lowerTier) continue;
                for (uint g = 0; g < gantries.length(); ++g) {
                    CCircuitDef@ gantry = ai.GetCircuitDef(gantries[g]);
                    if (gantry !is null && gantry.CanBuild(def)) { groundHeavyDefs.insertLast(def.GetName()); break; }
                }
            }
        }
    }
    void Configure(CAirWaveTask@ wave, bool offensive, int preference)
    {
        wave.SetOperationPolicy(offensive, preference, Global::Map::StartPos,
            Global::RoleSettings::Air::StrikeEscortLead, Global::RoleSettings::Air::StrikeBacklineRiskLimit,
            Global::RoleSettings::Air::StrikeDistrictRadius);
        wave.SetAttackHandoffPolicy(Global::RoleSettings::Air::StrikeEarlyAttack,
            offensive ? Global::RoleSettings::Air::StrikeImmediatePriority : 0.0f,
            Global::RoleSettings::Air::StrikeImmediateRadius);
        if (offensive) {
            // A committed wave exhausts each class before descending. This also
            // lets new waves finish a defeated base after its named targets die.
            wave.AddTargetFallback(3); // preserve the existing frontline assault fallback
            wave.AddTargetFallback(4); // other economy and support structures
            wave.AddTargetFallback(7); // approved heavy ground units
            wave.AddTargetFallback(0); // remaining structures
            if (Global::RoleSettings::Air::StrikeCleanupMobile) wave.AddTargetFallback(8);
        }
        InitHeavyRoster();
        for (uint i = 0; i < groundHeavyDefs.length(); ++i) wave.AllowStrikeDef(ai.GetCircuitDef(groundHeavyDefs[i]), 1.0f);
        const array<string> sides = {"armada", "cortex", "legion"};
        for (uint i = 0; i < sides.length(); ++i) {
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(sides[i])), 4.0f);
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(sides[i])), 3.0f);
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(sides[i])), 1.0f);
            wave.AllowStrikeDef(ai.GetCircuitDef(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(sides[i])), 0.5f);
        }
        wave.AllowStrikeDef(ai.GetCircuitDef("armckfus"), 1.0f); // real cloakable fusion; visibility gates still apply
        const array<string> advancedGeos = {"armageo", "corageo", "legageo", "armgmm",
            "armuwageo", "coruwageo", "leganavaladvgeo"};
        for (uint i = 0; i < advancedGeos.length(); ++i)
            wave.AllowStrikeDef(ai.GetCircuitDef(advancedGeos[i]), 0.75f);
        // Factory classifications are authoritative and include all enabled factions/options.
        array<string> defs = UnitHelpers::GetAllLabs();
        for (uint i = 0; i < defs.length(); ++i) wave.AllowStrikeDef(ai.GetCircuitDef(defs[i]), 2.0f);
        array<AIFloat3> starts = Lanes::ScriptStarts(true);
        for (uint i = 0; i < starts.length(); ++i) wave.AddSearchPoint(starts[i]);
        if (starts.length() == 0) wave.AddSearchPoint(AirScreen::Enemy(Global::Map::StartPos));
    }
    void Tick()
    {
        // Prune once per policy tick even when factories stop requesting new
        // aircraft; dead operations must not retain a growing ID/handle ledger.
        BomberCount("");
        for (int i = int(operations.length())-1; i >= 0; --i) {
            if (operations[i] is null || operations[i].IsDead()) {
                operations.removeAt(i); offensive.removeAt(i); launched.removeAt(i); struck.removeAt(i);
                continue;
            }
            const int state = operations[i].GetState();
            if (state == 3) struck[i] = true; // ATTACKING: the cohort left assembly on its run
            if (offensive[i] && state == 5)
                Invariants::Violation("INV-116", "AIR", "offensive bomber operation entered return state");
        }
        AirEscortScout::Tick();
        array<string>@ ids = escorts.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            if (ai.GetTeamUnit(parseInt(ids[i])) is null) escorts.delete(ids[i]);
            else if (Committed(parseInt(ids[i]))) {
                IUnitTask@ owner; escorts.get(ids[i], @owner);
                CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
                if (u !is null && u.task !is owner && u.task !is null && u.task.GetType() != int(Task::Type::PLAYER))
                    Invariants::Violation("INV-115", ids[i], "committed fighter left its live bomber operation");
            }
        }
    }
    void Reset()
    {
        array<string>@ ids = escorts.getKeys();
        array<IUnitTask@> tasks;
        for (uint i = 0; i < ids.length(); ++i) {
            IUnitTask@ task; escorts.get(ids[i], @task);
            if (task !is null && !task.IsDead() && tasks.findByRef(task) < 0) tasks.insertLast(task);
        }
        for (uint i = 0; i < operations.length(); ++i)
            if (operations[i] !is null && !operations[i].IsDead() && tasks.findByRef(operations[i]) < 0) tasks.insertLast(operations[i]);
        escorts.deleteAll(); bombers.deleteAll(); operations.resize(0); offensive.resize(0);
        launched.resize(0); struck.resize(0);
        for (uint i = 0; i < tasks.length(); ++i) tasks[i].Abort();
        AirEscortScout::Reset();
    }
    // D-291: Air_MilitaryAiTaskRemoved hook. Native DequeueTask calls
    // TaskRemoved before Stop (TaskModule.cpp), so the surviving members are
    // still listed here. A bombing run is an offensive operation that reached
    // ATTACKING with a real cohort; a zero-bomber abort at assembly is not one,
    // and neither is a defensive sortie or a naval escort (not in operations).
    // Cost: O(launched + members) once per removed AIR wave task.
    void OnTaskRemoved(IUnitTask@ task)
    {
        CAirWaveTask@ wave = cast<CAirWaveTask>(task);
        if (wave is null) return;
        const int i = operations.findByRef(wave);
        if (i < 0 || !offensive[i] || !struck[i] || launched[i].length() == 0) return;
        // The abort that removes the task usually runs inside the last bomber's
        // own UnitDestroyed (CAirWaveTask::RemoveAssignee aborts when units
        // empty; CircuitAI.cpp unregisters the team unit only afterwards), so
        // ai.GetTeamUnit still returns the dying bomber here. RemoveAssignee
        // has already handed it to the idle task, so "still on the run" is
        // `u.task is task`, never mere existence. A bomber transferred off the
        // run alive is not on the bombing run either (D-291 follow-up).
        if (wave.GetBomberCount() > 0) return;
        for (uint b = 0; b < launched[i].length(); ++b) {
            CCircuitUnit@ bomber = ai.GetTeamUnit(launched[i][b]);
            if (bomber !is null && bomber.task is task) return; // a bomber is still flying the run
        }
        array<CCircuitUnit@>@ members = task.GetUnits();
        array<int> fighters;
        for (uint m = 0; m < members.length(); ++m) {
            CCircuitUnit@ u = members[m];
            IUnitTask@ owner;
            if (u !is null && AirScreen::IsFighter(u.circuitDef) && escorts.get("" + u.id, @owner) && owner is task)
                fighters.insertLast(u.id); // only this operation's escorts
        }
        GenericHelpers::LogUtil("[AIR][EscortScout] wipe op=" + i + " bombersLaunched=" + launched[i].length()
            + " escorts=" + fighters.length(), 1);
        AirEscortScout::Plan(wave, fighters, i);
    }
}
