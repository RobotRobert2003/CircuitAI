#include "../../helpers/math/metal_math.as"
#include "metal_layout.as"

// All entry points are gated. The normal role controllers retain their exact
// sequence; metal mode supplies only the changed economic decisions.
namespace MetalEconomy {
    int CompactCampusAfterSeconds = 120;
    int InitialMexTarget = 40;
    array<int> workers = {-1, -1, -1};
    array<IBuilderTask@> cancelledMexes;
    int screenFrame = -100000;
    float ProductionShare = 0.7f;
    float GrowthMargin = 0.2f;
    float HomeRadius = 2400.0f;
    int OpeningDeadlineSeconds = 100;
    int OpeningMexBudget = 2;
    int EnergyParallel = 3;
    int DensityWindCount = 120;
    float DensityUnitShare = 0.65f;
    float InvestmentSeconds = 90.0f;
    int snapshotFrame = -100000, lastLog = -100000;
    float mi = 0, ei = 0, ratio = 25, goal = 120, bp = 0;
    int winds = 0, units = 0, pendingEnergy = 0;
    bool dense = false;

    bool Active() { return aiEconomyMgr.IsMetalMap(); }
    void Removed(IUnitTask@ task, bool done) {
        if (!Active() || done) return;
        IBuilderTask@ mex = cast<IBuilderTask>(task);
        if (mex !is null && mex.GetBuildType() == int(Task::BuildType::MEX)
            && mex.target is null && AiTaskReservationId(mex) >= 0) cancelledMexes.insertLast(mex);
    }
    void Read() {
        if (!Active() || ai.frame - snapshotFrame < SECOND) return;
        snapshotFrame = ai.frame;
        // Removal callbacks precede native Cancel. Retain the dead task only
        // until the next snapshot to verify its served pin was relinquished.
        for (uint i = 0; i < cancelledMexes.length(); ++i) {
            if (AiTaskReservationId(cancelledMexes[i]) >= 0)
                Invariants::Violation("INV-114", "field mex", "cancelled unframed task retained its served layout pin");
            else GenericHelpers::LogUtil("[METAL][Cancel] served mex pin released", 1);
        }
        cancelledMexes.resize(0);
        if (MetalLayout::Managed()) {
            for (uint w = 0; w < workers.length(); ++w) {
                workers[w] = aiTerrainMgr.GetLayoutInt("metal.worker." + w, -1);
                if (ai.GetTeamUnit(workers[w]) is null) workers[w] = -1;
            }
            array<Id>@ candidates = ai.GetOwnedUnitIds();
            for (uint i = 0; i < candidates.length(); ++i) {
                CCircuitUnit@ worker = ai.GetTeamUnit(candidates[i]);
                if (worker is null || worker.GetBuildProgress() < 1.0f || workers.find(worker.id) >= 0
                    || UnitHelpers::IsCommander(worker.circuitDef) || UnitHelpers::GetConstructorTier(worker.circuitDef) != 1
                    || MetalLayout::Mex() is null || !worker.circuitDef.CanBuild(MetalLayout::Mex())) continue;
                for (uint w = 0; w < workers.length(); ++w) if (workers[w] < 0) {
                    workers[w] = worker.id;
                    GenericHelpers::LogUtil("[METAL][Worker] assignment=" + w + " id=" + worker.id, 1);
                    break;
                }
            }
            for (uint w = 0; w < workers.length(); ++w) aiTerrainMgr.SetLayoutInt("metal.worker." + w, workers[w]);
            MetalLayout::Plan();
        }
        if (aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::CONVERT), null) > 0)
            Invariants::Violation("INV-111", "metal field", "converter construction queued in metal mode");
        mi = AiMax(0.0f, aiEconomyMgr.metal.income);
        ei = AiMax(0.0f, aiEconomyMgr.energy.income);
        ratio = 25.0f;
        if (Global::AISettings::Role == AiRole::AIR) {
            float work = 0, cm = 0, ce = 0;
            AirEconomy::Mix(AirEconomy::t2 > 0, work, cm, ce);
            if (cm > 0) ratio = ce / cm;
        }
        bp = 0; winds = 0; units = 0;
        pendingEnergy = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), null);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        units = int(ids.length());
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null) continue;
            IBuilderTask@ order = cast<IBuilderTask>(u.task);
            if (MetalLayout::Managed() && order !is null && order.GetBuildType() == int(Task::BuildType::MEX)
                && order.target !is null && AiTaskReservationId(order) >= 0
                && MapHelpers::SqDist(order.target.GetPos(ai.frame), aiTerrainMgr.GetReservationPos(AiTaskReservationId(order))) > 32.0f * 32.0f)
                Invariants::Violation("INV-112", "" + u.id, "field mex frame escaped its reserved module slot");
            const CCircuitDef@ d = u.circuitDef;
            if (d.GetName() == UnitHelpers::GetWindNameForSide(UnitHelpers::GetSideForUnitName(d.GetName()))) ++winds;
            if (u.GetBuildProgress() < 1.0f) {
                if (aiEconomyMgr.GetEnergyMake(d) > 0) ++pendingEnergy;
            } else if ((d.IsMobile() || d.GetName() == UnitHelpers::GetT1NanoNameForSide(UnitHelpers::GetSideForUnitName(d.GetName())))
                && MapHelpers::SqDist(u.GetPos(ai.frame), Global::Map::StartPos) < HomeRadius * HomeRadius) bp += d.GetBuildSpeed();
        }
        const int limit = aiEconomyMgr.GetEffectiveUnitLimit();
        dense = winds >= DensityWindCount || (limit > 0 && float(units) > float(limit) * DensityUnitShare);
        goal = AiMax(120.0f, MetalMath::EnergyGoal(mi * ProductionShare, ratio, 30.0f,
            AiMin(aiEconomyMgr.energy.pull, mi * (ratio + 10.0f)), GrowthMargin));
        if (ai.frame - lastLog >= 30 * SECOND) {
            lastLog = ai.frame;
            GenericHelpers::LogUtil("[METAL][Economy] M=" + int(mi) + " E=" + int(ei) + " goal=" + int(goal)
                + " fundedM=" + int(MetalMath::Sustainable(mi, ei, 30, ratio)) + " mex="
                + aiEconomyMgr.GetFieldMexCount(Global::Map::StartPos, HomeRadius) + " wind=" + winds + " dense=" + dense, 1);
        }
    }
    int OpeningCap() {
        const string side = Global::AISettings::Side;
        CCircuitDef@ mex = ai.GetCircuitDef(side == "armada" ? "armmex" : side == "cortex" ? "cormex" : "legmex");
        return mex !is null && aiEconomyMgr.GetFieldYield(mex, Global::Map::StartPos) > 10.0f ? 1 : OpeningMexBudget;
    }
    bool WantsMex() {
        Read();
        return MetalMath::NeedMex(mi, ei, ratio, aiEconomyMgr.metal.current, aiEconomyMgr.metal.storage, aiEconomyMgr.metal.pull);
    }
    bool AirScreenReady() {
        if (aiTerrainMgr.GetLayoutInt("metal.airScreen", 0) != 0) return true;
        if (ai.frame - screenFrame < SECOND) return false;
        screenFrame = ai.frame;
        int completed = 0;
        const string name = AirEconomy::Fighter(false);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.circuitDef.GetName() == name && u.GetBuildProgress() >= 1.0f) ++completed;
        }
        if (completed < Global::RoleSettings::Air::HomeFighterFloor) return false;
        aiTerrainMgr.SetLayoutInt("metal.airScreen", 1);
        GenericHelpers::LogUtil("[METAL][Transition] initial fighter screen complete", 1);
        return true;
    }
    IUnitTask@ DedicatedTask(CCircuitUnit@ u) {
        Read();
        if (!MetalLayout::Managed()) return null;
        IUnitTask@ task = null;
        if (u.id == workers[0]) {
            // A retreat or death may leave one of the forty committed mexes
            // without a builder. Finish that commitment before counting it done.
            @task = aiBuilderMgr.FindQueuedTask(u, int(Task::BuildType::MEX));
            if (task !is null) return task;
            if (aiEconomyMgr.GetFieldMexCount(Global::Map::StartPos, HomeRadius) < InitialMexTarget) {
                @task = MetalLayout::Build(u);
                return task !is null ? task : aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
            }
        }
        if (u.id == workers[1]) {
            if (ei < goal || aiEconomyMgr.isEnergyStalling) @task = PlaceEnergy(u);
            if (task is null) @task = Global::AISettings::Role == AiRole::AIR ? AirBuild::Assist(u, true)
                : Builder::EnqueueAssistEnergy(Task::Priority::HIGH, 10 * SECOND, 1);
            return task !is null ? task : aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
        }
        return null;
    }
    bool OpeningWorker(CCircuitUnit@ u) {
        Read();
        return u.id == workers[1]
            || (u.id == workers[0] && (aiEconomyMgr.GetFieldMexCount(Global::Map::StartPos, HomeRadius) < InitialMexTarget
                || aiBuilderMgr.FindQueuedTask(u, int(Task::BuildType::MEX)) !is null))
            || (u.id == workers[2] && aiTerrainMgr.GetLayoutInt("metal.techTransition", 0) == 0);
    }
    bool Funded(CCircuitDef@ d) {
        Read();
        return d !is null && !aiEconomyMgr.isEnergyStalling && MetalMath::CanInvest(mi, ei,
            aiEconomyMgr.metal.current, aiEconomyMgr.energy.current, d.costM, d.costE, InvestmentSeconds);
    }
    bool Can(CCircuitUnit@ u, CCircuitDef@ d) {
        return d !is null && u.circuitDef.CanBuild(d) && d.IsAvailable(ai.frame);
    }
    IUnitTask@ PlaceEnergy(CCircuitUnit@ u) {
        Read();
        if (pendingEnergy >= EnergyParallel) return null;
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const array<string> names = {UnitHelpers::GetWindNameForSide(side), UnitHelpers::GetSolarNameForSide(side),
            UnitHelpers::GetTidalNameForSide(side), UnitHelpers::GetAdvSolarNameForSide(side),
            UnitHelpers::GetFusionNameForSide(side), UnitHelpers::GetAdvFusionNameForSide(side)};
        array<CCircuitDef@> options;
        array<float> scores;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            // These caps belonged to the finite normal-map rush recipe. The
            // field controller owns funded energy growth, including recovery.
            if (d !is null && u.circuitDef.CanBuild(d) && d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
            if (!Can(u, d)) continue;
            float output = aiEconomyMgr.GetEnergyMake(d);
            if (i == 0) output = AiMin(25.0f, (ai.GetWindMin() + ai.GetWindMax()) * .5f);
            if (output <= 0) continue;
            if (i >= 4 && !Funded(d)) continue;
            if (i == 5 && (ei < 1500 || bp < 1000)) continue;
            if (aiEconomyMgr.energy.current < 100 && d.costE > 0 && ei < 10) continue;
            const float seconds = d.GetBuildTime() / AiMax(u.circuitDef.GetBuildSpeed(), AiMin(bp, 2500.0f));
            const float score = (d.costM / AiMax(mi, 1.0f) + d.costE / AiMax(ei, 10.0f) + seconds)
                / output + (dense ? 4.0f / output * 100.0f : 0.0f);
            uint at = scores.length();
            for (uint k = 0; k < scores.length(); ++k) if (score < scores[k]) { at = k; break; }
            scores.insertAt(at, score); options.insertAt(at, d);
        }
        for (uint k = 0; k < options.length(); ++k) {
            CCircuitDef@ best = options[k];
            IUnitTask@ t = null;
            if (Global::AISettings::Role == AiRole::AIR) @t = AirLayout::Place(u, best, Task::BuildType::ENERGY, Task::Priority::HIGH);
            else if (Global::AISettings::Role == AiRole::TECH) @t = Layout::Place(Task::BuildType::ENERGY, Task::Priority::HIGH, best, 0, u);
            else @t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::ENERGY, Task::Priority::HIGH, best, u.GetPos(ai.frame), 600, true, 0));
            if (t !is null) {
                ++pendingEnergy;
                GenericHelpers::LogUtil("[METAL][Build] energy " + best.GetName(), 1);
                return t;
            }
        }
        return null;
    }
    IUnitTask@ EconomyTask(CCircuitUnit@ u) {
        Read();
        IUnitTask@ t = null;
        if (ei < goal || aiEconomyMgr.isEnergyStalling) {
            @t = PlaceEnergy(u); if (t !is null) return t;
        }
        const bool mexWorker = Global::AISettings::Role != AiRole::AIR || !UnitHelpers::IsCommander(u.circuitDef);
        if (mexWorker && WantsMex() && aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, HomeRadius) < 2) {
            const AIFloat3 anchor = MetalLayout::Managed() ? Global::Map::StartPos : u.GetPos(ai.frame);
            @t = MetalLayout::Managed() ? MetalLayout::Build(u) : aiEconomyMgr.EnqueueMexWithin(u, anchor, HomeRadius, 0, true);
            if (t !is null) return t;
            // T2-only workers add density when expansion can't use their menu.
            if (UnitHelpers::GetConstructorTier(u.circuitDef) >= 2 && (dense || aiEconomyMgr.isMetalEmpty)) {
                @t = aiEconomyMgr.EnqueueFieldUpgrade(u, Global::Map::StartPos, HomeRadius);
                if (t !is null) return t;
            }
        }
        if (Global::AISettings::Role == AiRole::AIR) {
            @t = AirBuild::Nano(u); if (t !is null) return t;
            @t = AirBuild::Assist(u, ei < goal); if (t !is null) return t;
        }
        return null;
    }
    bool SkipTechRule(const string &in key) {
        return key == "air.dedicated" || key == "air.flex" || key == "chain.next"
            || key == "energy.convert.float" || key == "energy.convert" || key == "energy.reclaim"
            || key == "mex.expand" || key == "mex.upgrade" || key == "energy.draining"
            || key == "energy.short" || key == "eco.next" || key == "power.t1" || key == "power.turret";
    }
    IUnitTask@ AirTask(CCircuitUnit@ u) {
        Read();
        IUnitTask@ t = null;
        const bool commander = UnitHelpers::IsCommander(u.circuitDef);
        CCircuitUnit@ plant = AirBuild::NearestPlant(u);
        if (commander && plant !is null && AirEconomy::CompletedConstructors() < Global::RoleSettings::Air::OpeningAirConstructors)
            return AirBuild::Commander(u, plant);
        @t = DedicatedTask(u); if (t !is null) return t;
        @t = AirBuild::Resume(u); if (t !is null) return t;
        if (AirEconomy::t1 + AirEconomy::t2 == 0) {
            if (!MetalMath::OpeningDone(aiEconomyMgr.GetFieldMexCount(Global::Map::StartPos, 700), OpeningCap(),
                ai.frame / SECOND, OpeningDeadlineSeconds)) {
                @t = aiEconomyMgr.EnqueueMexWithin(u, Global::Map::StartPos, 700, 0, true); if (t !is null) return t;
            }
            if (ei < 80 && ai.frame < OpeningDeadlineSeconds * SECOND) {
                @t = PlaceEnergy(u); if (t !is null) return t;
            }
        }
        @t = AirBuild::Factory(u, false); if (t !is null) return t;
        if (AirEconomy::t2 == 0 && AirScreenReady()) {
            @t = AirBuild::Factory(u, true); if (t !is null) return t;
        }
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        if (ei >= 250) {
            @t = AirBuild::Utility(u, UnitHelpers::GetEnergyStorageNameForSide(side), Task::BuildType::STORE, 1);
            if (t !is null) return t;
            CCircuitDef@ next = ai.GetCircuitDef(AirEconomy::t2 > 0 ? UnitHelpers::GetAdvFusionNameForSide(side)
                : UnitHelpers::GetT2AirPlantForSide(side));
            if (next !is null && MetalMath::NeedInvestmentStorage(aiEconomyMgr.metal.current,
                aiEconomyMgr.metal.storage, next.costM)) {
                CCircuitDef@ store = ai.GetCircuitDef(UnitHelpers::GetMetalStorageNameForSide(side));
                if (store !is null && !AirBuild::Busy(store, Task::BuildType::STORE)) {
                    if (store.maxThisUnit <= store.count) store.maxThisUnit = store.count + 1;
                    @t = AirBuild::Utility(u, store.GetName(), Task::BuildType::STORE, store.count + 1);
                    if (t !is null) return t;
                }
            }
        }
        @t = EconomyTask(u); if (t !is null) return t;
        if (dense) { @t = AirReclaim::MakeTask(u); if (t !is null) return t; }
        @t = AirBuild::Factory(u, true); if (t !is null) return t;
        @t = AirDefence::MakeTask(u); if (t !is null) return t;
        @t = AirBuild::Utility(u, UnitHelpers::GetStaticRadarNameForSide(side), Task::BuildType::RADAR, 1);
        if (t !is null) return t;
        @t = AirBuild::Assist(u); if (t !is null) return t;
        if (commander && plant !is null && AirBuild::PlantHasWork(plant))
            return GuardHelpers::AssignWorkerGuard(u, plant, Task::Priority::NORMAL, false, 5 * SECOND);
        if (commander) u.CmdStop(); // WAIT preserves engine orders; end an old factory guard
        return aiBuilderMgr.Enqueue(TaskB::Wait(2 * SECOND));
    }
}
