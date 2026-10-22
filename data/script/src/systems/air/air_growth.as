#include "../construction/eco_planner.as"

// Shared economic choices; every task and reservation remains AIR-owned.
namespace AirGrowth {
    int lastLog = -100000;
    int lastBlockedLog = -100000;
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
        string why;
        string key = EcoPlanner::Decide(s, why);
        // The growth goal outranks a full bank's ordinary 'no more energy' answer,
        // after surplus conversion/build power have had their shared decisions.
        if (key.length() == 0 && s.builderIsT2 && !AirEconomy::GrowthComplete() && !s.energyBuilding)
            key = EcoPlanner::PickEnergy(s, why, "two-AFUS objective");
        IUnitTask@ task = null;
        if (key == "nano") @task = AirBuild::Nano(u);
        else if (key == "assistnano") @task = AirBuild::Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side)));
        else if (key == "assistenergy") @task = AssistReactor(u);
        else if (key.length() > 0) {
            CCircuitDef@ d = EcoPlanner::DefOf(key);
            const bool big = key == "fusion" || key == "afus";
            const Task::BuildType kind = EcoPlanner::TypeOf(key);
            if (AirBuild::Can(u, d) && (!big || AirEconomy::MexesReady())
                && !AirBuild::Busy(d, kind) && (!big || !s.energyBuilding)
                && (!(key == "t1conv" || key == "advconv") || !AirEconomy::MetalFloating()))
                @task = AirLayout::Place(u, d, kind, big ? Task::Priority::HIGH : Task::Priority::NORMAL, big);
        }
        if (task is null && reactor !is null) @task = AssistReactor(u);
        // A shared chooser answer may be temporarily unexecutable (for example
        // support already claimed by another worker). A full bank after the
        // bomber milestone must still permit funded, serial economic growth.
        if (task is null && s.builderIsT2 && AirEconomy::GrowthComplete() && AirEconomy::MexesReady()) {
            CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(side));
            if (AirBuild::Can(u, d) && AirMath::OverflowGrowth(AirEconomy::MetalFloating(), AirEconomy::recovery,
                s.energyBuilding || AirBuild::Busy(d, Task::BuildType::ENERGY), s.mCur, s.eCur, s.mIncome, s.eIncome,
                AirBuild::Committed(false), AirBuild::Committed(true), d.costM, d.costE,
                Global::RoleSettings::Air::ProductionIncomeShare, Global::RoleSettings::Air::OverflowGrowthSeconds)) {
                @task = AirLayout::Place(u, d, Task::BuildType::ENERGY, Task::Priority::NORMAL, true);
                if (task !is null) { key = "afus"; why = "funded surplus after production share and existing commitments"; }
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
