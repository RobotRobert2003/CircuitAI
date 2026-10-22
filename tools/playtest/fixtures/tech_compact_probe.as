// Supplied placement workload. Resource/strategy decisions are outside this
// fixture; layout admission, reach, claims, construction and loss stay real.
namespace TechCompactProbe {
    bool ready = false;
    bool displacedLab = false;
    int phase = 0;
    int lastDiagnostic = -100000;
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() < 2 || fields[0] != "tech-compact") return false;
        if (fields[1] == "setup" && fields.length() == 4) {
            if (!Global::Map::MapResolved) Setup::setupMap(AIFloat3(parseFloat(fields[2]), 0, parseFloat(fields[3])));
            Layout::OnRoleLeave();
            Layout::Plan(Global::AISettings::Side);
            TechChain::active = false; TechChain::done = true;
            if (displacedLab) {
                Layout::homeCentre = AIFloat3(8842.0f, 0.0f, 3184.0f);
                CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
                Layout::labSlot = aiTerrainMgr.ReservePersistentBuilding(lab, AIFloat3(9368.0f, 0.0f, 2488.0f), 0);
                aiTerrainMgr.SetLayoutInt(Layout::BOX + ".lab_slot", Layout::labSlot);
                TechChain::Init("nuke");
                GenericHelpers::LogUtil("[TechCompactTest] " + (Layout::labSlot >= 0 ? "PASS" : "FAIL") + " displaced_lab_reserved", 1);
            }
            ready = true;
        } else if (fields[1] == "adopt") {
            const uint before = CompactEco::groups.length();
            CompactEco::Adopt();
            GenericHelpers::LogUtil("[TechCompactTest] " + (before >= 4 && before == CompactEco::groups.length() ? "PASS" : "FAIL") + " native_group_adoption", 1);
        } else if (fields[1] == "turrets") phase = 0;
        else if (fields[1] == "economy") { phase = 1; TechChain::active = false; TechChain::done = true; }
        else if (fields[1] == "recover") phase = 2;
        return true;
    }
    IUnitTask@ Task(CCircuitUnit@ worker) {
        if (!ready || ai.teamId != 0 || worker is Builder::commander) return TechBuild::Wait(SECOND);
        if (!worker.circuitDef.IsMobile()) return TechRules::Evaluate(worker);
        IUnitTask@ current = TechBuild::KeepCurrent(worker);
        if (current !is null) return current;
        const string side = Global::AISettings::Side;
        if (phase < 0) {
            CCircuitDef@ store = ai.GetCircuitDef(UnitHelpers::GetEnergyStorageNameForSide(side));
            if (worker.circuitDef.CanBuild(store) && store.count + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::STORE), store) < 1) {
                IUnitTask@ task = Layout::Place(Task::BuildType::STORE, Task::Priority::HIGH, store, 300 * SECOND, worker);
                if (task !is null) return task;
            }
            IUnitTask@ support = CompactEco::SupportTask(worker);
            if (support !is null) return support;
        } else if (phase == 0) {
            CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
            if (nano.count + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO), nano) < 16 && worker.circuitDef.CanBuild(nano)) {
                IUnitTask@ task;
                if (displacedLab) {
                    TechChain::Step step("nano", nano.GetName(), 16);
                    @task = TechChain::Order(-1, @step, nano, worker);
                } else @task = Layout::NanoTask(worker, Task::Priority::HIGH);
                if (task !is null) return task;
                if (ai.frame - lastDiagnostic >= 30 * SECOND) {
                    lastDiagnostic = ai.frame;
                    for (uint g = 0; g < CompactEco::groups.length(); ++g) {
                        const int group = CompactEco::groups[g];
                        const int slot = aiTerrainMgr.NextSlotAny(group, worker.GetPos(ai.frame));
                        GenericHelpers::LogUtil("[TechCompactTest] waiting group=" + group + " slot=" + slot
                            + " state=" + aiTerrainMgr.GetReservationState(slot)
                            + " buildable=" + aiTerrainMgr.IsReservationBuildable(slot)
                            + " reachable=" + (slot >= 0 && aiTerrainMgr.CanReachAt(worker, aiTerrainMgr.GetReservationPos(slot), worker.circuitDef.GetBuildDistance())), 1);
                    }
                }
            }
        } else if (phase == 1) {
            // New economy pockets need their own support just as the ordinary
            // eco.compact.support rule does. The fixture holds that rule table.
            IUnitTask@ support = CompactEco::SupportTask(worker);
            if (support !is null) return support;
            const array<string> names = { UnitHelpers::GetAdvFusionNameForSide(side),
                UnitHelpers::GetAdvEnergyConverterNameForSide(side), UnitHelpers::GetEnergyStorageNameForSide(side) };
            // Leave useful conversion headroom after loss; six converters on
            // one reactor would correctly fail recovery's capacity admission.
            const array<int> counts = { 1, 3, 1 };
            const array<Task::BuildType> types = { Task::BuildType::ENERGY, Task::BuildType::CONVERT, Task::BuildType::STORE };
            for (uint index = 0; index < names.length(); ++index) {
                CCircuitDef@ def = ai.GetCircuitDef(names[index]);
                if (def is null || !worker.circuitDef.CanBuild(def)
                    || def.count + aiBuilderMgr.GetQueuedBuildCount(int(types[index]), def) >= counts[index]) continue;
                IUnitTask@ task = Layout::Place(types[index], Task::Priority::HIGH, def, 300 * SECOND, worker);
                if (task !is null) return task;
            }
        } else {
            IUnitTask@ task = TechBuild::RecoverEconomy(worker);
            if (task !is null) return task;
        }
        IUnitTask@ assist = TechBuild::AssistAny(worker, 2000.0f);
        return assist is null ? TechBuild::Wait(SECOND) : assist;
    }
}
