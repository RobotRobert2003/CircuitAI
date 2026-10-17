#include "../../systems/air/air_economy.as"
#include "../../helpers/construction/economy_helpers.as"
#include "../../systems/air/air_reclaim.as"
namespace AirBuild {
    IUnitTask@ starterReclaimTask;
    // One retained native task, committed only after successful enqueue. Removed
    // releases it; dead/completed tasks never reserve funds or block assistance.
    IUnitTask@ fundedFirstLab;
    array<IUnitTask@> projects;
    array<IUnitTask@> pendingOwnership;
    dictionary trace;
    dictionary nanoTrace;
    dictionary guardLeases;
    dictionary guardLeaseFrames;
    dictionary commanderFactoryGuards;
    int firstLabAttemptFrame = -1, firstLabAttemptBuilder = -1;
    bool ReactorPending()
    {
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ task = cast<IBuilderTask>(projects[i]);
            if (task is null || task.IsDead()) continue;
            if (AirMath::PendingReactor(IsReactor(task.buildDef), task.GetBuildType() == int(Task::BuildType::ENERGY),
                task.target !is null, task.target is null ? 0.0f : task.target.GetBuildProgress())) return true;
        }
        return false;
    }
    bool EconomyAircraft(CCircuitUnit@ u)
    {
        return u !is null && UnitHelpers::IsAirConstructor(u.circuitDef);
    }
    void AdoptExisting()
    {
        @fundedFirstLab = null;
        bool completedAdvanced = false;
        // A role handoff keeps native tasks alive. Observe their current owners
        // once on entry so old unframed support orders cannot bypass the layout.
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && UnitHelpers::IsT2AircraftPlant(u.circuitDef.GetName())
                && u.GetBuildProgress() >= 1.0f) completedAdvanced = true;
            IBuilderTask@ t = u is null ? null : cast<IBuilderTask>(u.task);
            if (t is null || t.IsDead() || t.GetBuildType() >= int(Task::BuildType::REPAIR)) continue;
            if (Global::RoleSettings::Air::FundFirstLab && t.buildDef !is null
                && t.GetBuildType() == int(Task::BuildType::FACTORY)
                && UnitHelpers::IsT2AircraftPlant(t.buildDef.GetName())) @fundedFirstLab = t;
            Added(t);
            if (t.target !is null && projects.findByRef(t) < 0) projects.insertLast(t);
        }
        if (completedAdvanced) @fundedFirstLab = null;
        // The previous role can leave orders with no assignee, so a unit-task
        // walk alone is incomplete. On entry, discard reachable unframed nano
        // orders before enabling the native layout-only queue filter. Framed
        // work remains owned and must finish. This never assigns the probe unit.
        const bool prior = aiBuilderMgr.experimentalBuild;
        aiBuilderMgr.experimentalBuild = false;
        dictionary checked;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || !u.circuitDef.IsMobile() || u.circuitDef.GetBuildSpeed() <= 0) continue;
            const string key = u.circuitDef.GetName();
            if (checked.exists(key)) continue;
            checked.set(key, true);
            for (int n = 0; n < 64; ++n) {
                IBuilderTask@ t = cast<IBuilderTask>(aiBuilderMgr.FindQueuedTask(u, int(Task::BuildType::NANO)));
                if (t is null || t.IsDead() || projects.findByRef(t) >= 0) break;
                if (t.target !is null) { projects.insertLast(t); break; }
                GenericHelpers::LogUtil("[AIR][Claim] cancel unassigned inherited nano", 1);
                CancelUnstarted(t);
            }
        }
        aiBuilderMgr.experimentalBuild = prior;
    }
    void ReturnEconomyWorkers()
    {
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (!EconomyAircraft(u) || u.GetBuildProgress() < 1.0f) continue;
            IBuilderTask@ task = cast<IBuilderTask>(u.task);
            if (task is null || task.GetBuildType() != int(Task::BuildType::GUARD)) continue;
            // Do not abort a guard shared with another worker. PLAYER/ferry tasks
            // are separate types and remain under their existing owner.
            IUnitTask@ wait = aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
            if (wait is null) continue;
            aiBuilderMgr.AssignTask(u, wait);
            u.CmdStop(); // Wait preserves the old engine guard unless explicitly cleared.
            GenericHelpers::LogUtil("[AIR][Economy] released economy aircraft " + ids[i] + " from guard", 1);
            @u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.task is task)
                Invariants::Violation("INV-106", "" + ids[i], "AIR economy constructor retained its guard");
        }
    }
    void Added(IUnitTask@ task)
    {
        IBuilderTask@ t = cast<IBuilderTask>(task);
        if (t is null) return;
        const int kind = t.GetBuildType();
        if (kind == int(Task::BuildType::NANO) || kind == int(Task::BuildType::FACTORY)
            || kind == int(Task::BuildType::ENERGY) || kind == int(Task::BuildType::CONVERT) || kind == int(Task::BuildType::STORE)
            || kind == int(Task::BuildType::DEFENCE) || kind == int(Task::BuildType::RADAR))
            pendingOwnership.insertLast(task);
    }
    void CancelUnstarted(IBuilderTask@ task)
    {
        if (task is null || task.IsDead() || task.target !is null) return;
        // Aborting an AI task does not clear its engine queue. In particular,
        // a travelling constructor can otherwise frame a cancelled reactor.
        array<CCircuitUnit@>@ workers = task.GetUnits();
        for (uint i = 0; i < workers.length(); ++i)
            if (workers[i] !is null && workers[i].task is task) workers[i].CmdStop();
        aiBuilderMgr.AbortTask(task);
    }
    void Tick()
    {
        AirReclaim::Tick();
        for (int i = int(projects.length()) - 1; i >= 0; --i) {
            if (projects[i] is null || projects[i].IsDead()) {
                GenericHelpers::LogUtil("[AIR][Claim] forget dead project", 1);
                projects.removeAt(i);
            }
        }
        ReturnEconomyWorkers();
        array<string>@ guards = guardLeases.getKeys();
        for (uint g = 0; g < guards.length(); ++g) {
            IUnitTask@ lease;
            int64 started = 0;
            guardLeases.get(guards[g], @lease);
            guardLeaseFrames.get(guards[g], started);
            CCircuitUnit@ worker = ai.GetTeamUnit(parseInt(guards[g]));
            if (worker is null || worker.task !is lease) {
                guardLeases.delete(guards[g]); guardLeaseFrames.delete(guards[g]);
            } else if (ai.frame - started > 30 * SECOND) {
                Invariants::Violation("INV-104", guards[g], "AIR fallback factory guard outlived its economic recheck lease");
            }
        }
        // A newly received/built mex can invalidate an unstarted reactor order.
        array<IUnitTask@> snapshot = projects;
        for (uint i = 0; i < snapshot.length(); ++i) {
            IBuilderTask@ t = cast<IBuilderTask>(snapshot[i]);
            if (t !is null && t.target is null && RequiresMexes(t.buildDef) && !AirEconomy::MexesReady()) {
                GenericHelpers::LogUtil("[AIR][Fusion] cancel unstarted advanced building: mex upgrades pending", 1);
                CancelUnstarted(t);
            }
            if (t !is null && t.target is null && t.buildDef !is null && t.GetBuildType() == int(Task::BuildType::FACTORY)
                && UnitHelpers::IsT2AircraftPlant(t.buildDef.GetName()) && !AirEconomy::ExistingT2SupportReady()) {
                GenericHelpers::LogUtil("[AIR][Support] cancel unstarted T2 lab: existing bays need completed turrets", 1);
                CancelUnstarted(t);
            }
        }
        // Native completion chains may enqueue economy work despite experimental
        // mode. Reconcile after Enqueue returns, so script can first claim its task.
        // Cancelling a native chain head can expose its next order immediately.
        // Drain those callbacks before auditing ownership, bounded against a
        // malformed self-replicating chain (which still trips INV-076 below).
        for (int round = 0; round < 16 && pendingOwnership.length() > 0; ++round) {
            array<IUnitTask@> pending = pendingOwnership;
            pendingOwnership.resize(0);
            for (uint i = 0; i < pending.length(); ++i) {
                // Native dormant chains now retain script handles when a parent
                // dies. Such links are tombstones, not newly available work.
                if (pending[i] is null || pending[i].IsDead()) continue;
                if (projects.findByRef(pending[i]) >= 0) continue;
                IBuilderTask@ t = cast<IBuilderTask>(pending[i]);
                if (t !is null && t.target is null) {
                    GenericHelpers::LogUtil("[AIR][Claim] cancel unowned native order " + (t.buildDef is null ? "?" : t.buildDef.GetName()), 1);
                    CancelUnstarted(t);
                }
            }
        }
        int queuedNanos = 0;
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ t = cast<IBuilderTask>(projects[i]);
            if (t !is null && t.GetBuildType() == int(Task::BuildType::NANO) && t.target is null) ++queuedNanos;
        }
        if (aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO), null) > queuedNanos)
            Invariants::Violation("INV-076", "AIR", "unclaimed native nano order remains after AIR reconciliation");
    }
    float Committed(bool energy)
    {
        float cost = 0.0f;
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ job = cast<IBuilderTask>(projects[i]);
            if (job is null || job.buildDef is null || job.GetBuildType() >= int(Task::BuildType::REPAIR)) continue;
            const float left = job.target is null ? 1.0f : 1.0f - job.target.GetBuildProgress();
            cost += (energy ? job.buildDef.costE : job.buildDef.costM) * AiMax(left, 0.0f);
        }
        return cost;
    }
    IBuilderTask@ FundedLab()
    {
        if (!Global::RoleSettings::Air::FundFirstLab || fundedFirstLab is null || fundedFirstLab.IsDead()) return null;
        IBuilderTask@ task = cast<IBuilderTask>(fundedFirstLab);
        return task is null || (task.target !is null && task.target.GetBuildProgress() >= 1.0f) ? null : task;
    }
    float LabReserve(bool energy)
    {
        IBuilderTask@ task = FundedLab();
        if (task is null || task.buildDef is null) return 0;
        const float left = task.target is null ? 1.0f : AiMax(0.0f, 1.0f - task.target.GetBuildProgress());
        return left * (energy ? task.buildDef.costE : task.buildDef.costM);
    }
    float LabCommitments(bool energy, CCircuitUnit@ except = null)
    {
        // O(P) over owned projects on admission only; investments already live
        // in the once-per-second workforce ledger, including queued recruits.
        float cost = energy ? AirWorkforce::committedE + AirWorkforce::admittedE
            : AirWorkforce::committedM + AirWorkforce::admittedM;
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ task = cast<IBuilderTask>(projects[i]);
            if (task is null || task.IsDead() || task.buildDef is null
                || task.GetBuildType() >= int(Task::BuildType::REPAIR)
                || AirWorkforce::Investment(task.buildDef) || (except !is null && task.target is except)) continue;
            const float left = task.target is null ? 1.0f : AiMax(0.0f, 1.0f - task.target.GetBuildProgress());
            cost += left * (energy ? task.buildDef.costE : task.buildDef.costM);
        }
        return cost;
    }
    bool LabBudget(const CCircuitDef@ def, float power, float fraction = 1.0f, CCircuitUnit@ target = null)
    {
        if (def is null || AirWorkforce::metalRates.length() < 10) return false;
        return AirMath::LabFunding(TeamEconomy::OwnMetal(TeamEconomy::CURRENT),
            Global::RoleSettings::Air::WorkforceReserveMetal, AirWorkforce::incomeM,
            AirWorkforce::usageM + AirWorkforce::admittedUsageM, LabCommitments(false, target),
            def.costM * fraction, def.GetBuildTime() * fraction, power,
            Global::RoleSettings::Air::FirstLabFundingSeconds, Global::RoleSettings::Air::FirstLabIncomeShare)
            && AirMath::LabFunding(TeamEconomy::OwnEnergy(TeamEconomy::CURRENT),
            Global::RoleSettings::Air::WorkforceReserveEnergy, AirWorkforce::incomeE,
            AirWorkforce::usageE + AirWorkforce::admittedUsageE, LabCommitments(true, target),
            def.costE * fraction, def.GetBuildTime() * fraction, power,
            Global::RoleSettings::Air::FirstLabFundingSeconds, Global::RoleSettings::Air::FirstLabIncomeShare);
    }
    bool FirstLabFunded(CCircuitUnit@ worker, CCircuitDef@ def)
    {
        return Global::RoleSettings::Air::FundFirstLab && worker !is null && def !is null
            && AirEconomy::t2 == 0 && !MetalEconomy::Active() && !AirEconomy::recovery
            && AirEconomy::Planned(def, Task::BuildType::FACTORY) == 0
            && ai.frame >= Global::RoleSettings::Air::TransitionEarliestSeconds * SECOND
            && aiTerrainMgr.GetLayoutInt("air.screen.established", 0) != 0
            && AirWorkforce::incomeM >= Global::RoleSettings::Air::FusionAccessMinMetal
            && AirWorkforce::incomeE >= Global::RoleSettings::Air::FusionAccessMinEnergy
            && LabBudget(def, worker.circuitDef.GetBuildSpeed());
    }
    IUnitTask@ TransitionMex(CCircuitUnit@ worker)
    {
        if (!Global::RoleSettings::Air::FundFirstLab || FundedLab() !is null
            || UnitHelpers::IsCommander(worker.circuitDef) || AirEconomy::recovery
            || AirEconomy::MexCount() >= Global::RoleSettings::Air::PreFusionMexLimit
            || TeamEconomy::OwnMetal(TeamEconomy::CURRENT) < Global::RoleSettings::Air::WorkforceReserveMetal
            || aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, Global::RoleSettings::Air::HomeMexRadius) > 0) return null;
        // Finite pre-fusion mex count and one local claim bound the investment;
        // native reachability/ownership checks reject unavailable allied spots.
        IUnitTask@ task = aiEconomyMgr.EnqueueMexWithin(worker, Global::Map::StartPos,
            Global::RoleSettings::Air::HomeMexRadius, 0, true);
        IBuilderTask@ build = cast<IBuilderTask>(task);
        if (build is null || build.buildDef is null) return task;
        // Inspect the actual native-selected extractor, including content/mod
        // variants. This cheap growth must fit cash after prior obligations.
        if (TeamEconomy::OwnMetal(TeamEconomy::CURRENT) < Global::RoleSettings::Air::WorkforceReserveMetal
                + LabCommitments(false) + build.buildDef.costM
            || TeamEconomy::OwnEnergy(TeamEconomy::CURRENT) < Global::RoleSettings::Air::WorkforceReserveEnergy
                + LabCommitments(true) + build.buildDef.costE) {
            CancelUnstarted(build);
            return null;
        }
        return task;
    }
    bool Can(CCircuitUnit@ u, CCircuitDef@ d) { return d !is null && d.IsAvailable(ai.frame) && u.circuitDef.CanBuild(d); }
    bool Busy(CCircuitDef@ d, Task::BuildType type)
    {
        return d !is null && (aiBuilderMgr.GetUnfinishedCount(d) > 0 || aiBuilderMgr.GetQueuedBuildCount(int(type), d) > 0);
    }
    IUnitTask@ Record(IUnitTask@ t, const string &in rule, CCircuitUnit@ u)
    {
        if (t is null) return null;
        AirWorkforce::Assign(u, t);
        IBuilderTask@ previous = cast<IBuilderTask>(u.task);
        if (EconomyAircraft(u) && previous !is null && previous.GetBuildType() == int(Task::BuildType::GUARD))
            u.CmdStop(); // Construction may wait for a path; clear the engine guard once.
        if (UnitHelpers::IsCommander(u.circuitDef)) {
            const string key = "" + u.id;
            if (rule == "opening.commander.guard" || rule == "commander.factory.guard") {
                commanderFactoryGuards.set(key, true);
            } else if (commanderFactoryGuards.exists(key)) {
                // A new construction task can wait on its path before issuing
                // any engine order. End the old guard at the ownership handoff,
                // not repeatedly on each idle tick or by aborting a shared task.
                u.CmdStop();
                commanderFactoryGuards.delete(key);
                GenericHelpers::LogUtil("[AIR][Commander] cleared factory guard for " + rule, 1);
            }
        }
        if (rule == "production.assist") {
            if (EconomyAircraft(u)) Invariants::Violation("INV-106", "" + u.id, "AIR economy constructor assigned production guard");
            guardLeases.set("" + u.id, @t);
            guardLeaseFrames.set("" + u.id, int64(ai.frame));
        }
        IBuilderTask@ build = cast<IBuilderTask>(t);
        if (build !is null && build.target is null && build.GetBuildType() == int(Task::BuildType::ENERGY)
            && IsReactor(build.buildDef) && projects.findByRef(t) < 0 && ReactorPending())
            Invariants::Violation("INV-108", "AIR", "new reactor order while another owned reactor project is unfinished");
        if (build !is null && build.buildDef !is null && build.target is null
            && build.GetBuildType() == int(Task::BuildType::DEFENCE)
            && !AirHome::Within(build.GetBuildPos(), Global::RoleSettings::Air::HomeDefenceRadius))
            Invariants::Violation("INV-091", "AIR", "static defence ordered outside own base");
        if (rule == "opening.mex" && AirEconomy::MexCount() >= 3)
            Invariants::Violation("INV-117", "AIR", "opening mex order exceeds three owned extractors");
        if (rule == "transition.storage") {
            CCircuitDef@ lab=ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
            if (lab is null || !AirMath::TransitionStorage(AirEconomy::t2>0,
                AirEconomy::bankM,aiEconomyMgr.metal.storage,lab.costM))
                Invariants::Violation("INV-118","AIR","transition storage admitted without a full undersized pre-T2 bank");
        }
        if (rule == "mex.expand" && build !is null && !AirHome::Within(build.GetBuildPos(), Global::RoleSettings::Air::HomeMexRadius))
            Invariants::Violation("INV-092", "AIR", "new mex expansion ordered outside home area");
        if (build !is null && build.buildDef !is null && build.target is null
            && build.GetBuildType() == int(Task::BuildType::DEFENCE)
            && build.buildDef.GetName() == UnitHelpers::GetAntiNukeNameForSide(UnitHelpers::GetSideForUnitName(build.buildDef.GetName()))
            && !PlacementMath::CoversCore(aiBattle.InterceptorCoverage(build.buildDef), MapHelpers::SqDist(build.GetBuildPos(), Global::Map::StartPos), Global::RoleSettings::Air::AntiNukeCoreRadius))
            Invariants::Violation("INV-094", "AIR", "anti-nuke placement does not cover own economic core");
        if (rule == "commander.factory.guard" && !PlantHasWork(NearestPlant(u)))
            Invariants::Violation("INV-081", "" + u.id, "AIR commander renewed guard on idle factory after opening crew");
        if (UnitHelpers::IsCommander(u.circuitDef) && NearestPlant(u) !is null
            && build !is null && (build.GetBuildType() == int(Task::BuildType::MEX) || build.GetBuildType() == int(Task::BuildType::MEXUP)))
            Invariants::Violation("INV-079", "AIR", "commander dispatched to mex work after factory exists");
        if (build !is null && build.target is null && RequiresMexes(build.buildDef) && !AirEconomy::MexesReady())
            Invariants::Violation("INV-077", "AIR", "reactor ordered while owned mex upgrades remain");
        if (build !is null && build.GetBuildType() == int(Task::BuildType::FACTORY)
            && build.target is null && build.buildDef !is null && UnitHelpers::IsT2AircraftPlant(build.buildDef.GetName())
            && !AirEconomy::Transition(build.buildDef) && t !is fundedFirstLab)
            Invariants::Violation("INV-083", "AIR", "T2 air lab ordered without income, bank or a funded first-lab admission");
        if (build !is null && build.target is null && build.buildDef !is null && build.GetBuildType() == int(Task::BuildType::FACTORY)
            && UnitHelpers::IsT2AircraftPlant(build.buildDef.GetName()) && !AirEconomy::ExistingT2SupportReady())
            Invariants::Violation("INV-090", "AIR", "additional T2 lab ordered before every existing lab has twenty completed support turrets");
        // Repair tasks also carry the target's definition, but own no building slot.
        if (build !is null && build.GetBuildType() == int(Task::BuildType::ENERGY) && build.buildDef !is null && build.buildDef.GetName()
            == UnitHelpers::GetWindNameForSide(UnitHelpers::GetSideForUnitName(build.buildDef.GetName()))) {
            const int slot = AiTaskReservationId(t);
            bool clustered = false;
            for (uint i = 0; i < AirLayout::windClusters.length(); ++i) {
                if (AirLayout::windClusters[i].slots.length() != 6) continue;
                for (uint s = 0; s < 6; ++s) {
                    const int planned = AirLayout::windClusters[i].slots[s];
                    // A required pin is served on assignment, after Record.
                    if (planned >= 0 && (build.target !is null ? aiTerrainMgr.GetReservationUnit(planned) is build.target
                        : slot >= 0 ? slot == planned : MapHelpers::SqDist(build.GetBuildPos(),
                        aiTerrainMgr.GetReservationPos(planned)) < 1.0f)) clustered = true;
                }
            }
            if (!clustered) Invariants::Violation("INV-078", "AIR", "wind order is outside a six-slot cluster");
        }
        if (projects.findByRef(t) < 0) projects.insertLast(t);
        const string key = "" + u.id;
        string prior = ""; trace.get(key, prior);
        if (prior != rule) { trace.set(key, rule); GenericHelpers::LogUtil("[AIR][Rule] " + rule + " builder=" + u.id, 1); }
        return t;
    }
    void Removed(IUnitTask@ t)
    {
        if (t is fundedFirstLab) @fundedFirstLab = null;
        const int i = projects.findByRef(t);
        if (i >= 0) projects.removeAt(i);
        const int p = pendingOwnership.findByRef(t);
        if (p >= 0) pendingOwnership.removeAt(p);
    }
    IUnitTask@ Resume(CCircuitUnit@ u, bool energyOnly = false)
    {
        // A killed/reassigned builder can leave a pinned order with no frame.
        // Busy/committed accounting must not strand that order forever.
        array<int> kinds = { int(Task::BuildType::ENERGY), int(Task::BuildType::FACTORY),
            int(Task::BuildType::NANO), int(Task::BuildType::STORE), int(Task::BuildType::CONVERT),
            int(Task::BuildType::DEFENCE), int(Task::BuildType::RADAR) };
        for (uint i = 0; i < (energyOnly ? 1 : kinds.length()); ++i) {
            IUnitTask@ t = aiBuilderMgr.FindQueuedTask(u, kinds[i]);
            IBuilderTask@ build = cast<IBuilderTask>(t);
            if (build !is null && build.target is null && RequiresMexes(build.buildDef) && !AirEconomy::MexesReady()) continue;
            if (build !is null && build.target is null && build.buildDef !is null && build.GetBuildType() == int(Task::BuildType::FACTORY)
                && UnitHelpers::IsT2AircraftPlant(build.buildDef.GetName()) && !AirEconomy::ExistingT2SupportReady()) continue;
            if (t !is null && projects.findByRef(t) >= 0) return t;
        }
        return null;
    }
    CCircuitUnit@ FindAssistTarget(CCircuitUnit@ u, bool energyOnly = false, CCircuitDef@ only = null, bool inReach = false, float radius = 1800.0f)
    {
        CCircuitUnit@ nearest = null;
        const float reach = inReach ? u.circuitDef.GetBuildDistance() : radius;
        float best = reach * reach;
        IBuilderTask@ lab = FundedLab();
        bool labChecked = false, labAffordable = false;
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ t = cast<IBuilderTask>(projects[i]);
            if (t is null || t.buildDef is null || t.target is null || Lifecycle::IsRetiring(t.target)) continue;
            if (t.target.GetBuildProgress() >= 1.0f) continue;
            if (energyOnly && t.GetBuildType() != int(Task::BuildType::ENERGY)) continue;
            if (only !is null && t.buildDef !is only) continue;
            if (!AirHome::EconomySite(t.target.GetPos(ai.frame))) continue;
            const float distance = MapHelpers::SqDist(u.GetPos(ai.frame), t.target.GetPos(ai.frame));
            if (distance > best || !aiTerrainMgr.CanReachAt(u, t.target.GetPos(ai.frame), u.circuitDef.GetBuildDistance())) continue;
            if (lab !is null && lab.target is t.target) {
                // Many repair leases can reference one frame. Budget once for
                // this search, keeping it O(P), not O(P^2), with no stale cache.
                if (!labChecked) {
                    const float already = AirWorkforce::Assigned(t.target, u);
                    labAffordable = already <= 0 || LabBudget(t.buildDef,
                        already + u.circuitDef.GetBuildSpeed(),
                        AiMax(0.0f, 1.0f - t.target.GetBuildProgress()), t.target);
                    labChecked = true;
                }
                if (!labAffordable) continue;
            }
            if (!AirWorkforce::Useful(t.target, u)) continue;
            best = distance; @nearest = t.target;
        }
        return nearest;
    }
    float AssignedPower(CCircuitUnit@ target, CCircuitUnit@ except)
    {
        return AirWorkforce::Assigned(target, except);
    }
    IUnitTask@ Assist(CCircuitUnit@ u, bool energyOnly = false, CCircuitDef@ only = null, bool inReach = false, float radius = 1800.0f)
    {
        CCircuitUnit@ target = FindAssistTarget(u, energyOnly, only, inReach, radius);
        return target is null ? null : aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, target, 20 * SECOND));
    }
    CCircuitUnit@ NearestPlant(CCircuitUnit@ u)
    {
        CCircuitUnit@ result = null;
        float best = 1.0e20f;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ plant = ai.GetTeamUnit(ids[i]);
            if (plant is null || Lifecycle::IsRetiring(plant)) continue;
            const string name = plant.circuitDef.GetName();
            if (!UnitHelpers::IsT1AircraftPlant(name) && !UnitHelpers::IsT2AircraftPlant(name)) continue;
            const float distance = MapHelpers::SqDist(u.GetPos(ai.frame), plant.GetPos(ai.frame));
            if (distance < best) { best = distance; @result = plant; }
        }
        return result;
    }
    bool PlantHasWork(CCircuitUnit@ plant)
    {
        if (plant is null || Lifecycle::IsRetiring(plant)) return false;
        if (plant.GetBuildProgress() < 1.0f) return true;
        IBuilderTask@ job = cast<IBuilderTask>(plant.task);
        return job !is null && !job.IsDead() && job.GetBuildType() == int(Task::BuildType::RECRUIT)
            && job.target !is null && job.target.GetBuildProgress() < 1.0f;
    }
    IUnitTask@ Commander(CCircuitUnit@ u, CCircuitUnit@ plant)
    {
        const int crew = AirEconomy::CompletedConstructors();
        const bool opening = !ProductionMath::CrewReady(crew, Global::RoleSettings::Air::OpeningAirConstructors);
        const bool useful = ProductionMath::FactoryAssistUseful(!opening, plant.GetBuildProgress() >= 1.0f, PlantHasWork(plant));
        IUnitTask@ t = null;
        if (!opening && !AirEconomy::recovery && AirEconomy::OpeningSupportNeeded()) {
            @t = Nano(u, true);
            if (t !is null) return Record(t, "opening.support", u);
            @t = Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)), true);
            if (t !is null) return Record(t, "opening.support.assist", u);
        }
        if (!opening && AirEconomy::SavingForFirstLab()) {
            @t = Nano(u);
            if (t !is null) return Record(t, "transition.support", u);
            @t = Assist(u, false, null, true);
            if (t !is null) return Record(t, "transition.finish", u);
            u.CmdStop();
            return Record(aiBuilderMgr.Enqueue(TaskB::Wait(3 * SECOND)), "transition.save", u);
        }
        // Finish the factory before branching. During the crew opening, nearby
        // energy recovery is the only exception to guarding production.
        if (plant.GetBuildProgress() >= 1.0f && (!opening || (AirEconomy::recovery && AirEconomy::bankE < 200.0f))) {
            const float target = AiMax(160.0f, AiMax(AirEconomy::metal * 45.0f, AirEconomy::demandE * 1.3f));
            if (AirEconomy::energy < target || AirEconomy::recovery) {
                @t = Assist(u, true, null, true);
                if (t !is null) return Record(t, "commander.energy.assist", u);
                @t = Energy(u, AirEconomy::recovery);
                if (t !is null) return Record(t, "commander.energy.local", u);
            }
            if (!opening) {
                @t = Nano(u);
                if (t !is null) return Record(t, "commander.support", u);
                @t = Convert(u);
                if (t !is null) return Record(t, "commander.convert", u);
                @t = Assist(u, false, null, true);
                if (t !is null) return Record(t, "commander.local.assist", u);
            }
        }
        if (!useful) {
            // Assist the structure the aircraft is building, never chase the
            // aircraft itself. A short move beats guarding an idle factory.
            @t = Assist(u, AirEconomy::recovery, null, false, Global::RoleSettings::Air::CommanderEconomyRadius);
            if (t !is null) return Record(t, "commander.idle.assist", u);
            @t = Energy(u, AirEconomy::recovery, Global::RoleSettings::Air::CommanderEconomyRadius);
            if (t !is null) return Record(t, "commander.idle.energy", u);
            // Builder wait deliberately preserves engine commands. End the
            // old guard as well as its task when there is no useful target.
            u.CmdStop();
            return Record(aiBuilderMgr.Enqueue(TaskB::Wait(SECOND)), "commander.idle.wait", u);
        }
        @t = GuardHelpers::AssignWorkerGuard(u, plant, Task::Priority::HIGH, false, 5 * SECOND);
        return Record(t is null ? aiBuilderMgr.Enqueue(TaskB::Wait(SECOND)) : t,
            opening ? "opening.commander.guard" : "commander.factory.guard", u);
    }
    bool StarterReadyToRetire(CCircuitUnit@ plant)
    {
        if (plant is null || !UnitHelpers::IsT1AircraftPlant(plant.circuitDef.GetName())
            || Team::Ferry::requestPending || aiTerrainMgr.GetLayoutInt("air.starter.retired", 0) != 0
            || AirEconomy::CompletedConstructors() < Global::RoleSettings::Air::OpeningAirConstructors
            || AirScreen::HomeValue() < Global::RoleSettings::Air::HomeFighterFloor * 70.0f) return false;
        CCircuitDef@ advanced = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        if (!AirEconomy::Transition(advanced)) return false;
        for (uint b = 0; b < AirLayout::bays.length(); ++b)
            if (AirLayout::bays[b].defName == advanced.GetName() && AirLayout::bays[b].slot >= 0) return true;
        return false;
    }
    IUnitTask@ RetireStarter(CCircuitUnit@ worker)
    {
        if (worker is null || !worker.circuitDef.IsMobile()) return null;
        CCircuitUnit@ retiring = ai.GetTeamUnit(aiTerrainMgr.GetLayoutInt("air.starter.retiringId", -1));
        if (retiring !is null) {
            if (starterReclaimTask !is null && !starterReclaimTask.IsDead()) return null;
            @starterReclaimTask = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, retiring, 120*SECOND));
            return starterReclaimTask;
        }
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ plant = ai.GetTeamUnit(ids[i]);
            if (!StarterReadyToRetire(plant) || plant.GetBuildProgress() < 1.0f || PlantHasWork(plant)) continue;
            if (!aiTerrainMgr.CanReachAt(worker, plant.GetPos(ai.frame), worker.circuitDef.GetBuildDistance())) continue;
            IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, plant, 120*SECOND));
            if (task is null) return null;
            @starterReclaimTask = task;
            Lifecycle::Retire(plant, "AIR starter funds advanced production; rebuild in planned campus later");
            aiTerrainMgr.SetLayoutInt("air.starter.retired", 1);
            aiTerrainMgr.SetLayoutInt("air.starter.retiringId", plant.id);
            return task;
        }
        return null;
    }
    IUnitTask@ NearbyStarter(CCircuitUnit@ u, CCircuitDef@ lab)
    {
        const AIFloat3 at = u.GetPos(ai.frame);
        const float clear = float(AiMax(lab.GetFootprintX(),lab.GetFootprintZ()))*8.0f + 48.0f;
        for (int ring = int(clear/32)+1; ring <= 20; ++ring) {
            for (int k = 0; k < ring*8; ++k) {
                const float angle = 6.2831853f*float(k)/float(ring*8);
                AIFloat3 point(at.x+cos(angle)*ring*32,0,at.z+sin(angle)*ring*32);
                for (int facing = 0; facing < 4; ++facing) {
                    if (!aiTerrainMgr.CanReserveBuilding(lab,point,facing)) continue;
                    const int slot = aiTerrainMgr.ReserveBuilding(lab,point,facing);
                    if (slot < 0) continue;
                    IUnitTask@ task = AirLayout::Pinned(Task::BuildType::FACTORY,Task::Priority::NOW,lab,slot);
                    if (task is null) { aiTerrainMgr.ReleaseReservation(slot); return null; }
                    aiTerrainMgr.SetLayoutInt("air.starter.ordered",1);
                    GenericHelpers::LogUtil("[AIR][Starter] nearby distance="+int(sqrt(MapHelpers::SqDist(at,point))),1);
                    return task;
                }
            }
        }
        return null;
    }
    IUnitTask@ Factory(CCircuitUnit@ u, bool advanced)
    {
        const string name = advanced ? UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side) : UnitHelpers::GetT1AirPlantForSide(Global::AISettings::Side);
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (!Can(u, d) || Busy(d, Task::BuildType::FACTORY)) return null;
        const int count = AirEconomy::Planned(d, Task::BuildType::FACTORY);
        if (!advanced && count > 0) return null;
        if (!advanced && aiTerrainMgr.GetLayoutInt("air.starter.retired",0) != 0 && !Team::Ferry::requestPending
            && (AirEconomy::t2 == 0 || !AirEconomy::HasAdvancedBuilder() || AirEconomy::bankM < d.costM)) return null;
        if (!advanced && UnitHelpers::IsCommander(u.circuitDef) && AirEconomy::t1+AirEconomy::t2 == 0
            && !AirEconomy::HasMobileConstructor()) {
            IUnitTask@ nearby = NearbyStarter(u,d);
            if (nearby !is null) return nearby;
        }
        if (advanced) {
            if (!AirEconomy::Transition(d) && !FirstLabFunded(u, d)) return null;
            if (!AirEconomy::ExistingT2SupportReady()) return null;
            if (!AirMath::BayAllowed(count, Global::RoleSettings::Air::MaxProductionBays)) return null;
            if (!AirEconomy::BankedLab(d) && count > 0 && (AirEconomy::stableSince < 0 || !ProductionMath::CapacityReady(count, (Global::RoleSettings::Air::MaxProductionBays <= 0 ? count + 1 : Global::RoleSettings::Air::MaxProductionBays),
                ai.frame - AirEconomy::stableSince, Global::RoleSettings::Air::CapacityStableSeconds * SECOND,
                AirEconomy::bankM, d.costM * 0.6f))) return null;
            if (count == 0) { firstLabAttemptFrame = ai.frame; firstLabAttemptBuilder = u.id; }
        }
        AirLayout::Bay@ bay = null;
        for (uint b = 0; b < AirLayout::bays.length(); ++b) {
            AirLayout::Bay@ candidate = AirLayout::bays[b];
            if (candidate.defName != name || candidate.cluster < 0 || candidate.factoryId >= 0) continue;
            @candidate = AirLayout::Activate(candidate);
            if (candidate is null || aiTerrainMgr.GetReservationState(candidate.slot) != 0) continue;
            // Match native factory access admission before allocating work.
            // A refusal by this worker does not invalidate another's slot.
            if (!aiTerrainMgr.CanReachAtSafe(u, aiTerrainMgr.GetReservationPos(candidate.slot), u.circuitDef.GetBuildDistance())) continue;
            @bay = candidate; break;
        }
        if (bay is null) @bay = AirLayout::Reserve(d, advanced ? Global::Map::StartPos : u.GetPos(ai.frame));
        if (bay is null) return null;
        @bay = AirLayout::Activate(bay);
        if (bay is null) return null;
        if (!aiTerrainMgr.CanReachAtSafe(u, aiTerrainMgr.GetReservationPos(bay.slot), u.circuitDef.GetBuildDistance())) return null;
        if (advanced) GenericHelpers::LogUtil("[AIR][LabGate] M10=" + int(Economy::GetMinMetalIncomeLast10s())
            + " window=" + Economy::IncomeWindowReady() + " bank=" + int(aiEconomyMgr.metal.current)
            + " cost=" + int(d.costM) + " reason=" + (AirEconomy::BankedLab(d) ? "bank" : AirEconomy::Transition(d) ? "income" : "funded-first"), 1);
        IUnitTask@ order = AirLayout::Pinned(Task::BuildType::FACTORY, Task::Priority::HIGH, d, bay.slot);
        if (order !is null && advanced && count == 0 && Global::RoleSettings::Air::FundFirstLab)
            @fundedFirstLab = order;
        // Native claims protect queued work; frame adoption commits the bay.
        return order;
    }
    bool RequiresMexes(CCircuitDef@ d)
    {
        return !MetalEconomy::Active() && IsReactor(d);
    }
    IUnitTask@ Convert(CCircuitUnit@ u)
    {
        if (AirEconomy::recovery || AirEconomy::MexesReady()
            || AirEconomy::bankE < aiEconomyMgr.energy.storage * 0.75f) return null;
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetEnergyConverterNameForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
        if (!Can(u, d)) return null;
        const int queued = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::CONVERT), d);
        const int target = ProductionMath::ConverterTarget(AirEconomy::energy, AirEconomy::demandE,
            Global::RoleSettings::Air::ConverterEnergyReserve, Global::RoleSettings::Air::ConverterDraw);
        if (!ProductionMath::ConverterMayQueue(target, d.count + queued, queued,
                Global::RoleSettings::Air::ConverterParallel)) return null;
        return AirLayout::Place(u, d, Task::BuildType::CONVERT, Task::Priority::NORMAL);
    }
    bool IsReactor(const CCircuitDef@ d)
    {
        if (d is null) return false;
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        return d.GetName() == UnitHelpers::GetFusionNameForSide(side)
            || d.GetName() == UnitHelpers::GetAdvFusionNameForSide(side);
    }
    IUnitTask@ UpgradeMex(CCircuitUnit@ u)
    {
        if (AirEconomy::recovery || AirEconomy::energy < 350.0f) return null;
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
        if (!Can(u, d)) return null;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        CCircuitUnit@ nearest = null;
        float distance = 1.0e20f;
        bool remoteBusy = false;
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ job = cast<IBuilderTask>(projects[i]);
            if (job !is null && !job.IsDead() && job.GetBuildType() == int(Task::BuildType::MEXUP)
                && !AirHome::Within(job.GetBuildPos(), Global::RoleSettings::Air::HomeMexRadius)) remoteBusy = true;
        }
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ mex = ai.GetTeamUnit(ids[i]);
            if (mex is null || !AirEconomy::NeedsMexUpgrade(mex.circuitDef) || mex.GetBuildProgress() < 1.0f) continue;
            const AIFloat3 pos = mex.GetPos(ai.frame);
            if (remoteBusy && !AirHome::Within(pos, Global::RoleSettings::Air::HomeMexRadius)) continue;
            if (Economy::MexTracker::AnyUpgradeInProgressNear(pos, 48.0f)
                || !aiTerrainMgr.CanReachAt(u, pos, u.circuitDef.GetBuildDistance())) continue;
            const float sq = MapHelpers::SqDist(u.GetPos(ai.frame), pos);
            if (sq < distance) { distance = sq; @nearest = mex; }
        }
        if (nearest is null) return null;
        return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, d, nearest.GetPos(ai.frame), -1));
    }
    IUnitTask@ AssistMex(CCircuitUnit@ u)
    {
        if (AirEconomy::recovery) return null;
        for (uint i = 0; i < AirEconomy::owned.length(); ++i) {
            CCircuitUnit@ mex = ai.GetTeamUnit(AirEconomy::owned[i]);
            if (mex is null || mex.circuitDef.GetExtractsMetal() <= 0.0f || mex.GetBuildProgress() >= 1.0f) continue;
            if (!AirHome::Within(mex.GetPos(ai.frame), Global::RoleSettings::Air::HomeMexRadius)) continue;
            if (!ProductionMath::AssistUseful(AssignedPower(mex, u), mex.circuitDef.GetBuildTime(), mex.GetBuildProgress(), 20.0f)) continue;
            if (MapHelpers::SqDist(u.GetPos(ai.frame), mex.GetPos(ai.frame)) > 1800.0f * 1800.0f) continue;
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, mex, 20 * SECOND));
        }
        return null;
    }
    IUnitTask@ FirstFusion(CCircuitUnit@ u)
    {
        if (!AirEconomy::PreparingFusion() || AirEconomy::recovery || !AirEconomy::MexesReady()) return null;
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(Global::AISettings::Side));
        if (!Can(u, d) || Busy(d, Task::BuildType::ENERGY)) return null;
        if (!ProductionMath::Funded(AirEconomy::bankM, AirEconomy::metal * 0.6f, 150.0f, Committed(false), d.costM, 180.0f)
            || !ProductionMath::Funded(AirEconomy::bankE, AirEconomy::energy * 0.5f, 500.0f, Committed(true), d.costE, 180.0f)) return null;
        IUnitTask@ t = AirLayout::Place(u, d, Task::BuildType::ENERGY, Task::Priority::HIGH, true);
        if (t !is null) GenericHelpers::LogUtil("[AIR][Fusion] first fusion admitted: all owned mexes upgraded; target="
            + Global::RoleSettings::Air::FirstFusionTargetSeconds + "s", 1);
        return t;
    }
    IUnitTask@ Energy(CCircuitUnit@ u, bool emergency, float walkRadius = 0.0f)
    {
        int pending = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), null);
        for (uint i = 0; i < AirEconomy::owned.length(); ++i) {
            CCircuitUnit@ frame = ai.GetTeamUnit(AirEconomy::owned[i]);
            if (frame !is null && frame.GetBuildProgress() < 1.0f && aiEconomyMgr.GetEnergyMake(frame.circuitDef) > 0.0f) ++pending;
        }
        if (pending >= Global::RoleSettings::Air::EnergyParallel) return null;
        const string side = Global::AISettings::Side;
        const bool t2 = UnitHelpers::GetConstructorTier(u.circuitDef) >= 2;
        if (!emergency && AirEconomy::TechGrowth() && AirEconomy::HasReactor() && !t2) return null;
        array<string> names;
        const string fusion = UnitHelpers::GetFusionNameForSide(side);
        const string advancedFusion = UnitHelpers::GetAdvFusionNameForSide(side);
        // A floating metal bank does not supply the work or energy for an AFUS.
        // Establish ordinary reactor income before committing the small AIR crew.
        bool reactorIncome = false;
        for (uint i = 0; i < AirEconomy::owned.length(); ++i) {
            CCircuitUnit@ reactor = ai.GetTeamUnit(AirEconomy::owned[i]);
            if (reactor !is null && reactor.GetBuildProgress() >= 1.0f
                && (reactor.circuitDef.GetName() == fusion || reactor.circuitDef.GetName() == advancedFusion)) {
                reactorIncome = true; break;
            }
        }
        const bool mexesReady = AirEconomy::MexesReady();
        if (!emergency && t2 && mexesReady && reactorIncome && AirEconomy::metal >= 80.0f && AirEconomy::bankM > 5000.0f) names.insertLast(advancedFusion);
        if (!emergency && t2 && mexesReady && AirEconomy::metal >= 30.0f && AirEconomy::bankM > 500.0f) names.insertLast(fusion);
        const float wind = (ai.GetWindMin() + ai.GetWindMax()) * 0.5f;
        const string advSolar = UnitHelpers::GetAdvSolarNameForSide(side);
        if (!emergency && AirEconomy::metal >= 15.0f && AirEconomy::bankE >= 1800.0f && AirEconomy::Count(advSolar) < 6)
            names.insertLast(advSolar);
        if (wind > Global::RoleSettings::Air::GoodWindMinimumEnergy && (!emergency || ai.GetWindMin() > 4.0f)) names.insertLast(UnitHelpers::GetWindNameForSide(side));
        if (!emergency && AirEconomy::metal > 15.0f && AirEconomy::bankE > 1500.0f) names.insertLast(UnitHelpers::GetAdvSolarNameForSide(side));
        names.insertLast(UnitHelpers::GetSolarNameForSide(side));
        names.insertLast(UnitHelpers::GetTidalNameForSide(side));
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (!Can(u, d)) continue;
            const bool reactor = names[i] == UnitHelpers::GetFusionNameForSide(side) || names[i] == UnitHelpers::GetAdvFusionNameForSide(side);
            if (!reactor && AirEconomy::CompletedAfus() > 0) continue;
            if (reactor && (Busy(ai.GetCircuitDef(fusion), Task::BuildType::ENERGY) || Busy(ai.GetCircuitDef(advancedFusion), Task::BuildType::ENERGY))) continue;
            if (!reactor && !ProductionMath::Funded(AirEconomy::bankM, AirEconomy::metal * 0.6f, 50.0f, float(pending) * d.costM, d.costM, 20.0f)) continue;
            IUnitTask@ task = AirLayout::Place(u, d, Task::BuildType::ENERGY, emergency ? Task::Priority::NOW : Task::Priority::NORMAL, reactor, walkRadius);
            if (task !is null) return task;
        }
        return null;
    }
    int SupportCommitted(uint bay)
    {
        if (bay >= AirEconomy::nanoCount.length()) return 0;
        int count = AirEconomy::nanoCount[bay] + AirEconomy::nanoFuture[bay];
        for (uint i = 0; i < projects.length(); ++i) {
            IBuilderTask@ task = cast<IBuilderTask>(projects[i]);
            if (task is null || task.IsDead() || task.target !is null || task.GetBuildType() != int(Task::BuildType::NANO)) continue;
            if (AirEconomy::SupportBay(task.buildDef, task.GetBuildPos()) == int(bay)) ++count;
        }
        return count;
    }
    IUnitTask@ Nano(CCircuitUnit@ u, bool openingOnly = false)
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        const string key = "" + u.id;
        int64 logged = -100000;
        if (nanoTrace.exists(key)) nanoTrace.get(key, logged);
        if (ai.frame - logged >= 30 * SECOND && AirEconomy::metal >= 30.0f && d !is null) {
            nanoTrace.set(key, int64(ai.frame));
            GenericHelpers::LogUtil("[AIR][NanoGate] " + u.circuitDef.GetName() + " " + u.id + " can=" + (Can(u, d) ? "yes" : "no")
                + " busy=" + (Busy(d, Task::BuildType::NANO) ? "yes" : "no") + " count=" + d.count, 1);
        }
        const bool openingSupport = AirEconomy::OpeningSupportNeeded();
        if (openingOnly && !openingSupport) return null;
        if (!Can(u, d) || AirEconomy::recovery) return null;
        if (BuildPowerMath::Batch(AirWorkforce::constructionPower, d.GetBuildTime(),
            Global::RoleSettings::Air::WorkforceSupportSeconds, AirWorkforce::pendingSupport,
            Global::RoleSettings::Air::WorkforceSupportBatchMax) <= 0) return null;
        if (!openingOnly) {
            IUnitTask@ local = AirEcoLayout::Nano(u, d);
            if (local !is null) { AirWorkforce::Admit(d, true, true); return local; }
        }
        AirEconomy::RefreshSupport();
        for (uint b = 0; b < AirLayout::bays.length() && b < AirEconomy::nanoCount.length(); ++b) {
            if ((openingOnly || AirEconomy::energy < 250.0f) && (!UnitHelpers::IsT1AircraftPlant(AirLayout::bays[b].defName)
                || SupportCommitted(b) >= AirEconomy::OpeningNanoTarget())) continue;
            if (AirLayout::bays[b].factoryId < 0 || SupportCommitted(b) >= AirEconomy::NanoTarget(b)) continue;
            float work = 0, cm = 0, ce = 0;
            AirEconomy::Mix(UnitHelpers::IsT2AircraftPlant(AirLayout::bays[b].defName), work, cm, ce);
            // Only incremental throughput is new demand; cold-start time remains
            // part of the existing factory model and pending turrets count once.
            const float power = AirEconomy::power[b] + float(AiMax(0, SupportCommitted(b) - AirEconomy::nanoCount[b])) * d.GetBuildSpeed();
            const float delta = AiMax(0.0f, ProductionMath::Rate(work, power + d.GetBuildSpeed(), Global::RoleSettings::Air::WarmFactoryGapSeconds)
                - ProductionMath::Rate(work, power, Global::RoleSettings::Air::WarmFactoryGapSeconds));
            if (!AirWorkforce::Fund(d, u.circuitDef.GetBuildSpeed(), delta * cm, delta * ce)) continue;
            AirLayout::RepairSupport(b, d);
            for (uint s = 0; s < AirLayout::bays[b].nanos.length(); ++s) {
                const int slot = AirLayout::bays[b].nanos[s];
                if (aiTerrainMgr.GetReservationState(slot) != 0) continue;
                if (!aiTerrainMgr.CanReachAt(u, aiTerrainMgr.GetReservationPos(slot), u.circuitDef.GetBuildDistance())) continue;
                IUnitTask@ t = AirLayout::Pinned(Task::BuildType::NANO, Task::Priority::HIGH, d, slot);
                if (t !is null) { AirWorkforce::Admit(d, true); return t; }
            }
        }
        return null;
    }
    IUnitTask@ Utility(CCircuitUnit@ u, const string &in name, Task::BuildType type, int cap)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (!Can(u, d) || AirEconomy::Planned(d, type) >= cap) return null;
        return AirLayout::Place(u, d, type, Task::Priority::NORMAL);
    }
    void Leave()
    {
        AirWorkforce::Reset();
        AirProduction::Leave();
        array<IUnitTask@> tasks = projects;
        projects.resize(0);
        pendingOwnership.resize(0);
        for (uint i = 0; i < tasks.length(); ++i) aiBuilderMgr.AbortTask(tasks[i]);
        AirReclaim::jobs.resize(0);
        trace.deleteAll(); nanoTrace.deleteAll(); guardLeases.deleteAll(); guardLeaseFrames.deleteAll(); AirLayout::Leave();
    }
}
