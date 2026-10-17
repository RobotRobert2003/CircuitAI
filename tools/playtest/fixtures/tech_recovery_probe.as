// Supplied inputs only: real reservations, pinned tasks, recovery admission and
// factory callbacks. Lua independently observes physical completion/destruction.
namespace TechRecoveryProbe {
    bool active = false;
    string mode;
    int phase = 0;
    array<int> slots;
    const array<string> names = {"armnanotc", "armnanotc", "armestor", "armmmkr", "armnanotc"};
    const array<float> xs = {1400, 1464, 1584, 1760, 1000};
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() < 2 || fields[0] != "tech-recovery") return false;
        if (fields[1] == "setup") {
            mode = fields[2]; active = true;
            Global::AISettings::Role = AiRole::TECH;
            Global::AISettings::Side = "armada";
            if (!Global::Map::MapResolved) Setup::setupMap(AIFloat3(1400,0,10100));
            Global::RoleSettings::Tech::StrategyMask = uint(1) << uint(Strategy::T3_RUSH);
            TechChain::active = false; TechChain::done = true;
            if (mode == "recovery") {
                // Replace the unused opening plan with this supplied geometry.
                // The real native registry still owns all frame/loss transitions.
                Layout::OnRoleLeave();
                aiTerrainMgr.SetLayoutEnabled(true);
                for (uint i = 0; i < names.length(); ++i) {
                    CCircuitDef@ def = ai.GetCircuitDef(names[i]);
                    def.maxThisUnit = 100;
                    slots.insertLast(aiTerrainMgr.ReservePersistentBuilding(def, AIFloat3(xs[i],0,10100), 0));
                    GenericHelpers::LogUtil("[TechRecoveryTest] reserved index=" + i + " slot=" + slots[i], 1);
                    if (slots[i] < 0) GenericHelpers::LogUtil("[TechRecoveryTest] FAIL fixture reservation " + i, 1);
                }
            }
        } else if (fields[1] == "wave1") phase = 1;
        else if (fields[1] == "wave2") phase = 2;
        return true;
    }
    float MetalIncome() { return mode == "gantry" ? 250.0f : (phase == 2 ? 8.0f : 40.0f); }
    void Tick() {
        if (!active || ai.teamId != 0) return;
        // Supplied low income after converter loss tests the funded replacement
        // exception. Banks, energy capacity and construction remain engine state.
        TechChain::Tick();
        if (mode == "gantry" && Factory::lastGantryBatchUnit.length() > 0) {
            CCircuitDef@ product = ai.GetCircuitDef(Factory::lastGantryBatchUnit);
            if (aiFactoryMgr.GetPendingRecruitCount(product) > 5)
                GenericHelpers::LogUtil("[TechRecoveryTest] FAIL duplicate batch", 1);
        }
    }
    IUnitTask@ Task(CCircuitUnit@ u) {
        if (!active || ai.teamId != 0 || u is Builder::commander) return TechBuild::Wait(SECOND);
        if (!u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);
        IUnitTask@ current = TechBuild::KeepCurrent(u);
        if (current !is null) return current;
        if (mode != "recovery") return TechBuild::Wait(SECOND);
        if (phase == 0) {
            for (uint i = 0; i < slots.length(); ++i) {
                if (slots[i] < 0 || aiTerrainMgr.GetReservationState(slots[i]) != 0) continue;
                CCircuitDef@ def = ai.GetCircuitDef(names[i]);
                if (!u.circuitDef.CanBuild(def)) continue;
                const Task::BuildType type = i == 3 ? Task::BuildType::CONVERT : (i == 2 ? Task::BuildType::STORE : Task::BuildType::NANO);
                const int previous = Layout::activeTurretAdmissionBudget;
                Layout::activeTurretAdmissionBudget = 3; // supplied initial population only
                IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, def,
                    aiTerrainMgr.GetReservationPos(slots[i]), 0.0f, true, 300 * SECOND));
                Layout::activeTurretAdmissionBudget = previous;
                if (task !is null && AiPinReservation(task, slots[i])) return task;
                if (task !is null) aiBuilderMgr.AbortTask(task);
            }
            IUnitTask@ assist = TechBuild::AssistAny(u, 2000.0f);
            return assist is null ? TechBuild::Wait(SECOND) : assist;
        }
        // Hold extra supplied workers between loss waves; only a builder able
        // to replace a free lost slot enters the ordinary policy sequence.
        bool due = false;
        for (uint i = 0; i < slots.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(names[i]);
            if (aiTerrainMgr.GetReservationState(slots[i]) == 0 && aiTerrainMgr.GetLostReservationCount(def) > 0
                && u.circuitDef.CanBuild(def)) { due = true; break; }
        }
        if (!due) {
            IUnitTask@ assist = TechBuild::AssistAny(u, 2000.0f);
            return assist is null ? TechBuild::Wait(SECOND) : assist;
        }
        if (phase == 2) {
            if (u.id != TechBuild::airAfusId) return TechBuild::Wait(SECOND);
            EcoPlanner::ConversionDecision@ previous = EcoPlanner::conversionDecision;
            EcoPlanner::BeginConversionDecision(u);
            IUnitTask@ task = TechBuild::AirDedicated(u);
            EcoPlanner::EndConversionDecision(previous);
            IBuilderTask@ build = cast<IBuilderTask>(task);
            if (build !is null && build.buildDef !is null) {
                const bool correct = build.buildDef.GetName() == "armmmkr" && Economy::GetMinMetalIncomeLast10s() < 18.0f;
                GenericHelpers::LogUtil("[TechRecoveryTest] " + (correct ? "PASS" : "FAIL") + " dedicated_converter_precedes_afus income="
                    + Economy::GetMinMetalIncomeLast10s(), 1);
            }
            return task is null ? TechBuild::Wait(SECOND) : task;
        }
        // Exercise the actual ordered rule table, including KeepCurrent and
        // recovery before dedicated-air and discretionary economy expansion.
        return TechRules::Evaluate(u);
    }
}
