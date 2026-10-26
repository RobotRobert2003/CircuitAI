#include "../construction/eco_planner.as"

// Shared economic choices; every task and reservation remains AIR-owned.
namespace AirGrowth {
    int lastLog = -100000;
    int lastBlockedLog = -100000;
    int afusGateLogged = -1;   // D-366: -1 unknown, else the last logged allowAdvancedFusion; one line per transition
    IUnitTask@ AssistReactor(CCircuitUnit@ u)
    {
        // A flying worker can cross the home disc; the target still has to be
        // inside that disc. Ground gifts retain the ordinary travel limit.
        return AirBuild::Assist(u, true, null, false, UnitHelpers::IsAirConstructor(u.circuitDef)
            ? Global::RoleSettings::Air::HomeEconomyRadius * 2.0f : 1800.0f);
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!AirEconomy::TechGrowth()) return null;
        CCircuitDef@ firstLab = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        // Completed counts can change between the once-per-second snapshots.
        if (AirEconomy::t2 == 0 && AirEconomy::Planned(firstLab, Task::BuildType::FACTORY) == 0
            && AirBuild::Can(u, firstLab) && !AirBuild::Busy(firstLab, Task::BuildType::FACTORY)
            && AirEconomy::Transition(firstLab)) {
            if (AirBuild::firstLabAttemptFrame != ai.frame || AirBuild::firstLabAttemptBuilder != u.id)
                Invariants::Violation("INV-120", "AIR", "shared growth considered before eligible first-lab placement");
        }
        EcoPlanner::State@ s = EcoPlanner::Read(u, AirEconomy::metal, AirEconomy::energy, true);
        // AIR admitted its funded support request before this chooser. It must
        // not ask TECH's independent 8-BP/M rule to make a second decision.
        s.buildPowerNear = 0.0f;
        // The next reactor is an objective, even at a temporarily full bank.
        // Keep one reactor frame and focus mobile build power on it.
        CCircuitUnit@ reactor = null;
        const string side = Global::AISettings::Side;
        const array<string> reactors = {UnitHelpers::GetAdvFusionNameForSide(side), UnitHelpers::GetFusionNameForSide(side)};
        for (uint i = 0; i < reactors.length(); ++i) {
            @reactor = aiBuilderMgr.FindUnfinishedNear(Global::Map::StartPos,
                Global::RoleSettings::Air::HomeEconomyRadius, ai.GetCircuitDef(reactors[i]));
            if (reactor !is null) break;
        }
        s.energyGoal = AiMax(EcoPlanner::TargetEnergy(s.mIncome), AirEconomy::demandE * 1.3f);
        if (!AirEconomy::GrowthComplete()) s.energyGoal = AiMax(s.energyGoal, s.eIncome + 1.0f);
        // AIR can retain small, local T1 energy orders while its flying crew
        // scales reactors elsewhere. Generic ENERGY queues must not lock out
        // this district; only real owned reactor commitments serialize it.
        s.energyBuilding = AirBuild::ReactorPending() || reactor !is null;
        s.energyAssistable = reactor !is null;
        s.turretSlot = false;
        // D-366 (owner): AIR scales like SUPPORT (D-359): ordinary fusions, converters
        // alongside, until the energy-income gate; the advanced fusion only after it.
        const float afusGate = Global::RoleSettings::Air::AdvancedFusionEnergyIncome;
        s.allowAdvancedFusion = afusGate <= 0.0f || s.eIncome >= afusGate;
        if (s.builderIsT2 && (s.allowAdvancedFusion ? 1 : 0) != afusGateLogged) {
            afusGateLogged = s.allowAdvancedFusion ? 1 : 0;
            GenericHelpers::LogUtil("[AIR][Eco] advanced fusion " + (s.allowAdvancedFusion ? "allowed" : "withheld")
                + ": energy income " + int(s.eIncome) + " against gate " + int(afusGate), 1);
        }
        string why;
        string key = EcoPlanner::Decide(s, why);
        if (key == "afus" && !s.allowAdvancedFusion)
            Invariants::Violation("INV-241", "afus-gate", "AIR chose an advanced fusion under its energy-income gate");
        // The growth goal outranks a full bank's ordinary 'no more energy' answer,
        // after surplus conversion/build power have had their shared decisions.
        if (key.length() == 0 && s.builderIsT2 && !AirEconomy::GrowthComplete() && !s.energyBuilding)
            key = EcoPlanner::PickEnergy(s, why, "growth objective");   // ordinary fusions under the D-366 gate
        IUnitTask@ task = null;
        if (key == "nano") @task = AirBuild::Nano(u);
        else if (key == "assistnano") @task = AirBuild::Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side)));
        else if (key == "assistenergy") @task = AssistReactor(u);
        else if (key.length() > 0) {
            CCircuitDef@ d = EcoPlanner::DefOf(key);
            const bool big = key == "fusion" || key == "afus";
            const Task::BuildType kind = EcoPlanner::TypeOf(key);
            const bool converter = key == "t1conv" || key == "advconv";
            // D-368: converters go ConverterParallel at a time (ordered or framed); one at a
            // time left 12,000 of 16,000 energy floating at +3,800 for ten minutes while
            // twenty builders idled (played). Reactors stay one at a time.
            const bool open = converter
                ? aiBuilderMgr.GetQueuedBuildCount(int(kind), d) + aiBuilderMgr.GetUnfinishedCount(d) < Global::RoleSettings::Air::ConverterParallel
                : !AirBuild::Busy(d, kind);
            // D-368: a reactor waits while the income wants a plant the bank does not yet
            // hold (production.ladder runs first and needs PlantBankFraction of the cost;
            // played: a fusion affordable on projected income took the bank every time
            // and the second plant came ten minutes late). Converters and turrets go on.
            if (big && AirEconomy::PlantUnbanked()) { why = "advanced plant wanted first, bank " + int(s.mCur) + " of " + int(AirEconomy::PlantBankWanted()); key = ""; }
            else if (AirBuild::Can(u, d) && (!big || AirEconomy::MexesReady())
                && open && (!big || !s.energyBuilding)
                && (!converter || !AirEconomy::MetalFloating()))
                @task = AirLayout::Place(u, d, kind, big ? Task::Priority::HIGH : Task::Priority::NORMAL, big);
        }
        if (task is null && reactor !is null) @task = AssistReactor(u);
        // A shared chooser answer may be temporarily unexecutable (for example
        // support already claimed by another worker). A full bank after the
        // bomber milestone must still permit funded, serial economic growth.
        if (task is null && s.builderIsT2 && AirEconomy::GrowthComplete() && AirEconomy::MexesReady()) {
            // D-366: the overflow reactor is an ordinary fusion under the gate
            CCircuitDef@ d = ai.GetCircuitDef(s.allowAdvancedFusion ? UnitHelpers::GetAdvFusionNameForSide(side) : UnitHelpers::GetFusionNameForSide(side));
            if (AirBuild::Can(u, d) && AirMath::OverflowGrowth(AirEconomy::MetalFloating(), AirEconomy::recovery,
                s.energyBuilding || AirBuild::Busy(d, Task::BuildType::ENERGY), s.mCur, s.eCur, s.mIncome, s.eIncome,
                AirBuild::Committed(false), AirBuild::Committed(true), d.costM, d.costE,
                Global::RoleSettings::Air::ProductionIncomeShare, Global::RoleSettings::Air::OverflowGrowthSeconds)) {
                @task = AirLayout::Place(u, d, Task::BuildType::ENERGY, Task::Priority::NORMAL, true);
                if (task !is null) { key = s.allowAdvancedFusion ? "afus" : "fusion"; why = "funded surplus after production share and existing commitments"; }
            }
        }
        if (task !is null) {
            if (ai.frame - lastLog >= 10 * SECOND) {
                lastLog = ai.frame;
                GenericHelpers::LogUtil("[AIR][Growth] " + key + " reason=" + why + " AFUS="
                    + AirEconomy::CompletedAfus() + " M=" + int(s.mIncome) + " E=" + int(s.eIncome), 1);
            }
            return AirBuild::Record(task, "economy.shared." + key, u);
        }
        if (s.builderIsT2 && ai.frame - lastBlockedLog >= 30 * SECOND) {
            lastBlockedLog = ai.frame;
            CCircuitDef@ selected = EcoPlanner::DefOf(key);
            GenericHelpers::LogUtil("[AIR][Growth] deferred=" + key + " by=" + u.circuitDef.GetName()
                + " reason=" + why + " energyBuilding=" + s.energyBuilding + " reactor=" + (reactor !is null)
                + " can=" + AirBuild::Can(u, selected) + " busy=" + AirBuild::Busy(selected, EcoPlanner::TypeOf(key))
                + " mexReady=" + AirEconomy::MexesReady() + " M=" + int(s.mIncome) + " bank=" + int(s.mCur), 1);
        }
        return null;
    }
}
