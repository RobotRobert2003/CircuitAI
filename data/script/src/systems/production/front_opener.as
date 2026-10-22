// D-309. One finite FRONT production cohort; no world scans or periodic job.
// Role code chooses the sequence. This capability owns only the selected batch.
// Handles keep tasks alive for identity checks, never borrow unit pointers.
namespace FrontOpener {
    IUnitTask@ gather;
    array<IUnitTask@> recruits;
    array<int> members;
    array<bool> departed; // keep the finite admission record after death/transfer
    int factoryId = -1;
    int started = -1;
    int deadline = -1;
    int expected = 0;
    int admitted = 0;
    int batchSize = 0;
    int defId = -1;
    float unitPower = 0.0f;
    AIFloat3 rally;
    bool closed = true;

    bool Enabled() { return Global::RoleSettings::Front::VehicleTankOpenerChance > 0.0f; }
    bool WasQueued(const string &in part) {
        return Enabled() && aiTerrainMgr.GetLayoutInt("front.opener." + part) != 0;
    }
    void MarkQueued(const string &in part) {
        if (Enabled()) aiTerrainMgr.SetLayoutInt("front.opener." + part, 1);
    }

    CCircuitDef@ ChooseTank(CCircuitUnit@ factory, const string &in name, const string &in side) {
        const float chance = Global::RoleSettings::Front::VehicleTankOpenerChance;
        if (chance <= 0.0f || !UnitHelpers::IsT1VehicleLab(name)) return null;
        const string tank = side == "cortex" ? "corgator" : (side == "legion" ? "leghades" : "");
        if (tank == "") return null;
        CCircuitDef@ def = ai.GetCircuitDef(tank);
        if (def is null || !factory.circuitDef.CanBuild(def) || !def.IsAvailable(ai.frame)
            || def.power <= 0.0f) return null;
        // Forced 0/1 settings are deterministic and consume no random draw.
        // Treat AiDice's rare -1 endpoint as the ordinary opener (KI-628).
        if (chance < 1.0f) {
            const array<float> weights = {1.0f - chance, chance};
            if (AiDice(weights) != 1) return null;
        }
        return def;
    }

    // Match native IFighterTask's sum of UnitDef combat power, not metal cost.
    float RequiredPower() {
        float power = 0.0f;
        for (int i = 0; i < expected; ++i) power += unitPower;
        // Small relative tolerance covers subtraction/re-addition after retreat.
        return power * 0.99999f;
    }

    void Begin(CCircuitUnit@ factory, CCircuitDef@ def, int count) {
        factoryId = factory.id; defId = def.id;
        started = ai.frame;
        deadline = started + AiMax(1, Global::RoleSettings::Front::VehicleTankGatherSeconds) * SECOND;
        expected = count; batchSize = count; admitted = 0; unitPower = def.power;
        rally = factory.GetPos(ai.frame);
        members.resize(0); departed.resize(0); recruits.resize(0); @gather = null; closed = false;
        GenericHelpers::LogUtil("[FrontOpener] tank=" + def.GetName() + " count=" + count
            + " power=" + RequiredPower() + " factory=" + factoryId, 1);
    }

    void Recruit(IUnitTask@ task) {
        if (task !is null) recruits.insertLast(task);
        else { expected = AiMax(0, expected - 1); RefreshPower(); }
    }
    void RefreshPower() {
        if (gather !is null && !gather.IsDead()) aiMilitaryMgr.SetGatherPower(gather, RequiredPower());
    }
    void Close() {
        closed = true;
        if (gather !is null && !gather.IsDead()) aiMilitaryMgr.SetGatherPower(gather, 0.0f);
        @gather = null; // native manager retains the task until survivor release
        recruits.resize(0); members.resize(0); departed.resize(0);
    }
    void RecruitRemoved(IUnitTask@ task, bool done) {
        if (closed) return;
        for (uint i = 0; i < recruits.length(); ++i) {
            if (recruits[i] !is task) continue;
            recruits.removeAt(i);
            if (!done) { expected = AiMax(0, expected - 1); RefreshPower(); }
            return;
        }
    }

    bool OwnsFactory(CCircuitUnit@ unit) {
        if (closed || unit is null || unit.id != factoryId) return false;
        if (ai.frame >= deadline) { Close(); return false; }
        return true;
    }
    bool OwnsUnit(CCircuitUnit@ unit) {
        if (closed || unit is null || unit.GetProducerId() != factoryId
            || unit.circuitDef.id != defId) return false;
        const int member = members.find(unit.id);
        return member >= 0 && !departed[member];
    }

    bool Admit(CCircuitUnit@ unit) {
        if (closed || unit is null || unit.circuitDef is null) return false;
        if (ai.frame >= deadline) { Close(); return false; }
        // Register on military UnitAdded, before its first idle task request:
        // a completed tank can die in that interval (focused casualty case).
        // Producer/time exclude gifts and later factories; the admission record
        // also prevents a transferred member returning as another recruit.
        const int member = members.find(unit.id);
        if (member >= 0) return !departed[member];
        if (admitted >= batchSize || unit.circuitDef.id != defId
            || unit.GetProducerId() != factoryId || unit.GetProductionFrame() < started) return false;
        members.insertLast(unit.id); departed.insertLast(false); ++admitted;
        return true;
    }
    IUnitTask@ MilitaryTask(CCircuitUnit@ unit) {
        if (!Admit(unit)) return null;
        if (gather !is null && gather.IsDead()) { Close(); return null; }
        if (gather is null) {
            @gather = aiMilitaryMgr.EnqueueGather(TaskF::Defend(Task::FightType::RAID, RequiredPower()), rally, deadline);
            if (gather is null) { Close(); return null; }
        }
        return gather;
    }
    void UnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage) {
        if (closed || unit is null) return;
        const int member = members.find(unit.id);
        if (member < 0 || departed[member]) return;
        departed[member] = true;
        expected = AiMax(0, expected - 1); RefreshPower();
    }
    void FactoryRemoved(CCircuitUnit@ unit) {
        if (closed || unit is null || unit.id != factoryId) return;
        // Completion precedes idle assignment. Include finished idle members
        // in the released squad; never take a player, retreat or external task.
        // This bounded O(N) handoff runs only on the producer's loss.
        if (gather !is null && !gather.IsDead()) {
            for (uint i = 0; i < members.length(); ++i) {
                if (departed[i]) continue;
                CCircuitUnit@ member = ai.GetTeamUnit(members[i]);
                if (member !is null && member.task !is null && member.task.GetType() == Task::Type::IDLE)
                    aiMilitaryMgr.TransferUnit(member, gather);
            }
        }
        Close();
    }
    void TaskRemoved(IUnitTask@ task, bool done) {
        if (gather is task) { closed = true; @gather = null; recruits.resize(0); members.resize(0); departed.resize(0); }
    }
    void Load() {
        // Native tasks/recruit handles are ephemeral across load. Preserve the
        // queued markers (no duplicate scout/batch), release surviving units to
        // ordinary military policy instead of guessing which recruits survived.
        Close(); @gather = null;
    }
}
