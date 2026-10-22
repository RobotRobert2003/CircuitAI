// Staged only: real physical obstruction and legacy guard assignment.
namespace AirEconomyProbe {
    const bool controlled = true;
    int blocked = -1, workerId = -1, peerId = -1, injectedAt = -1;
    AIFloat3 blockedPos;
    IUnitTask@ guard;
    bool moved = false, released = false, worked = false, planned = false, adopted = false;
    int sampled = -100000;
    dictionary fusionsChecked; // fusion unit id -> reported once
    dictionary aiFusions;      // fusion frames seen as AirBuild project targets (not fixture gifts)
    void Tick()
    {
        if (ai.teamId != 0 || Global::AISettings::Role != AiRole::AIR) return;
        int t1 = 0, t2 = 0;
        for (uint b = 0; b < AirLayout::bays.length(); ++b) {
            if (UnitHelpers::IsT2AircraftPlant(AirLayout::bays[b].defName)) ++t2;
            else ++t1;
        }
        if (!planned && int(AirEcoLayout::modules.length()) >= Global::RoleSettings::Air::PlannedEcoModules && t2 >= 6 && t1 >= 1) {
            planned = true;
            GenericHelpers::LogUtil("[AirEconomyProbe] PASS opening reserves " + AirEcoLayout::modules.length() + " economy modules and " + (t1 + t2) + " factory bays", 1);
        }
        if (controlled && !adopted && ai.frame >= 300 && AirEcoLayout::modules.length() >= 2) {
            adopted = true;
            const int slot = AirEcoLayout::modules[0].slots[0], zone = AirEcoLayout::modules[0].zone;
            const uint count = AirEcoLayout::modules.length();
            AirEcoLayout::Init();
            const bool valid = AirEcoLayout::modules.length() == count && AirEcoLayout::modules[0].slots[0] == slot
                && AirEcoLayout::modules[0].zone == zone && aiTerrainMgr.GetReservationState(slot) == 0;
            GenericHelpers::LogUtil("[AirEconomyProbe] " + (valid ? "PASS" : "FAIL") + " named-state adoption preserves module slots and zones", 1);
        }
        if (controlled && ai.frame >= 450 && blocked < 0 && AirEcoLayout::modules.length() > 0) {
            AirEcoLayout::Module@ m = AirEcoLayout::modules[0];
            if (!m.started && m.slots.length() == 9) {
                blocked = m.slots[0]; blockedPos = aiTerrainMgr.GetReservationPos(blocked);
                WidgetLink::Send("layoutprobe", "block|" + blockedPos.x + "|" + blockedPos.z);
                GenericHelpers::LogUtil("[AirEconomyProbe] requested physical unused reactor blocker", 1);
            }
        }
        if (!moved && blocked >= 0 && AirEcoLayout::modules[0].slots.length() > 0
            && AirEcoLayout::modules[0].slots[0] != blocked) {
            moved = true;
            CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(Global::AISettings::Side));
            GenericHelpers::LogUtil("[AirEconomyProbe] " + (!aiTerrainMgr.CanReserveBuilding(d, blockedPos, AirLayout::facing) ? "PASS" : "FAIL")
                + " unused economic module relocated around physical wall", 1);
        }
        array<Id>@ ids = ai.GetOwnedUnitIds();
        if (controlled && workerId < 0 && ai.frame > 90 * SECOND && Factory::primaryT1AirPlant !is null) {
            for (uint i = 0; i < ids.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
                if (!AirBuild::EconomyAircraft(u) || u.GetBuildProgress() < 1.0f) continue;
                @guard = GuardHelpers::AssignWorkerGuard(u, Factory::primaryT1AirPlant, Task::Priority::NORMAL, false, 180 * SECOND);
                if (guard is null) continue;
                workerId = ids[i]; injectedAt = ai.frame;
                for (uint j = 0; j < ids.length(); ++j) {
                    CCircuitUnit@ peer = ai.GetTeamUnit(ids[j]);
                    if (peer is null || !UnitHelpers::IsAirConstructor(peer.circuitDef)
                        || UnitHelpers::GetConstructorTier(peer.circuitDef) != 1 || peer.GetBuildProgress() < 1.0f) continue;
                    peerId = ids[j];
                    aiBuilderMgr.AssignTask(peer, guard);
                    break;
                }
                aiBuilderMgr.AssignTask(u, guard);
                GenericHelpers::LogUtil("[AirEconomyProbe] " + (u.task is guard ? "confirmed" : "FAIL")
                    + " injected legacy production guard into T2 aircraft=" + workerId, 1);
                break;
            }
        }
        CCircuitUnit@ worker = workerId < 0 ? null : ai.GetTeamUnit(workerId);
        if (!released && worker !is null && worker.task !is guard) {
            released = true;
            GenericHelpers::LogUtil("[AirEconomyProbe] " + (ai.frame - injectedAt <= 5 * SECOND ? "PASS" : "FAIL")
                + " T2 constructor left injected guard in frames=" + (ai.frame - injectedAt), 1);
            CCircuitUnit@ peer = peerId < 0 ? null : ai.GetTeamUnit(peerId);
            GenericHelpers::LogUtil("[AirEconomyProbe] " + (peer !is null && peer.task is guard ? "PASS" : "FAIL")
                + " T1 peer retained the shared production guard", 1);
        }
        if (!worked && released && worker !is null) {
            IBuilderTask@ task = cast<IBuilderTask>(worker.task);
            const CCircuitDef@ d = task is null ? null : task.buildDef;
            if (task !is null && task.target !is null) @d = task.target.circuitDef;
            if (d !is null && AirEcoLayout::Managed(d)) {
                worked = true;
                GenericHelpers::LogUtil("[AirEconomyProbe] PASS recovered T2 aircraft working advanced economy " + d.GetName(), 1);
            }
        }
        if (ai.frame - sampled >= 10 * SECOND) {
            sampled = ai.frame;
            int total = 0, guarding = 0, economy = 0;
            for (uint i = 0; i < ids.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
                if (!AirBuild::EconomyAircraft(u) || u.GetBuildProgress() < 1.0f) continue;
                ++total;
                IBuilderTask@ task = cast<IBuilderTask>(u.task);
                if (task is null) continue;
                if (task.GetBuildType() == int(Task::BuildType::GUARD)) ++guarding;
                const CCircuitDef@ d = task.target is null ? task.buildDef : task.target.circuitDef;
                if (d !is null && AirEcoLayout::Managed(d)) ++economy;
            }
            GenericHelpers::LogUtil("[AirEconomyProbe] workers=" + total + " guard=" + guarding + " advancedEco=" + economy, 1);
            // D-292: every fusion AIR built itself stands on slot 0 of a fusion-kind
            // module. Fixture-supplied reactors (growth scenario gives fusions) are
            // never AirBuild projects, so only frames seen on a project are judged.
            for (uint i = 0; i < AirBuild::projects.length(); ++i) {
                IBuilderTask@ t = cast<IBuilderTask>(AirBuild::projects[i]);
                if (t !is null && !t.IsDead() && t.target !is null && AirEcoLayout::IsFusion(t.target.circuitDef))
                    aiFusions.set("" + t.target.id, AirEcoLayout::fallbackTasks.findByRef(AirBuild::projects[i]) >= 0);
            }
            for (uint i = 0; i < ids.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
                if (u is null || u.GetBuildProgress() < 1.0f || !AirEcoLayout::IsFusion(u.circuitDef)
                    || !aiFusions.exists("" + u.id) || fusionsChecked.exists("" + u.id)) continue;
                fusionsChecked.set("" + u.id, true);
                bool onModule = false;
                for (uint m = 0; m < AirEcoLayout::modules.length() && !onModule; ++m)
                    onModule = AirEcoLayout::modules[m].kind == AirEcoLayout::KindFusion
                        && AirEcoLayout::modules[m].slots.length() > 0
                        && aiTerrainMgr.GetReservationUnit(AirEcoLayout::modules[m].slots[0]) is u;
                bool fallback = false;
                aiFusions.get("" + u.id, fallback);
                const AIFloat3 pos = u.GetPos(ai.frame);
                GenericHelpers::LogUtil("[AirEconomyProbe] " + (onModule ? "PASS fusion on module slot "
                    : fallback ? "NOTE fusion on logged fallback site " : "FAIL fusion off layout ")
                    + u.circuitDef.GetName() + " " + int(pos.x) + "," + int(pos.z), 1);
            }
        }
    }
}
