#include "../../helpers/math/gantry_math.as"
#include "../../helpers/math/heavy_rush_math.as"

// TECH-only policy over the existing factory reservations and native recovery.
// No private factory registry, army scan, command loop or random draw.
namespace TechGantry {
    GantryMath::IncomeWindow metalWindow;
    int earlyStartFrame = -1;
    bool earlyDeferred = false;
    int nextLogFrame = 0;

    bool RecoveryEnabled() {
        return Global::AISettings::Role == AiRole::TECH
            && Global::RoleSettings::Tech::ExperimentalBuild
            && Global::RoleSettings::Tech::LayoutEnabled
            && Global::RoleSettings::Tech::GantryClusterRecoveryEnabled;
    }
    bool EarlyEnabled() {
        return RecoveryEnabled() && Global::RoleSettings::Tech::EarlyGantryEnabled
            && TechPlan::plan == "t3rush";
    }
    void SampleIncome() {
        if (!EarlyEnabled() || EarlyComplete()) return;
        metalWindow.Push(ai.frame, aiEconomyMgr.metal.income,
            Global::RoleSettings::Tech::EarlyGantryIncomeWindowSeconds * SECOND,
            Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND);
    }
    CCircuitDef@ OpeningUnit() {
        // Preserve the current signature production choice. Do not introduce
        // the other branch's ten-unit composition or override amphibious policy.
        return ai.GetCircuitDef(UnitHelpers::GetGantrySignatureUnitForSide(Global::AISettings::Side));
    }
    // D-364: `grossIncome` funds on the 10-second minimum metal income itself. The
    // default subtracts the current usage, which a TECH spending its income never
    // clears (at +1,000 metal and +1,000 usage the net is 0), so the gantry the
    // income step made due could only be funded by a bank above its whole cost.
    bool Funded(CCircuitDef@ factory, bool includeOpeningUnit, bool grossIncome = false) {
        if (factory is null) return false;
        float metalCost = factory.costM, energyCost = factory.costE;
        if (includeOpeningUnit) {
            CCircuitDef@ opening = OpeningUnit();
            if (opening is null || !factory.CanBuild(opening)) return false;
            metalCost += opening.costM; energyCost += opening.costE;
        }
        const float metalIncome = grossIncome ? Economy::GetMinMetalIncomeLast10s()
            : AiMax(0.0f, Economy::GetMinMetalIncomeLast10s() - TeamEconomy::OwnMetal(TeamEconomy::USAGE));
        const float availableEnergy = HeavyRushMath::AvailableEnergy(
            Economy::GetMinEnergyIncomeLast10s(), TeamEconomy::OwnEnergy(TeamEconomy::USAGE),
            ai.GetTeamRulesParam("mmUse", 0.0f), Global::RoleSettings::Tech::GantryEnergyReserve);
        return HeavyRushMath::CanFund(metalCost, energyCost, metalIncome, availableEnergy,
            aiEconomyMgr.metal.current, aiEconomyMgr.energy.current,
            Global::RoleSettings::Tech::GantryFundingSeconds,
            Global::RoleSettings::Tech::GantryFundingShare, 0.0f);
    }
    // owner, 2026-10-26: the early checks fund on gross income like D-364 (net income is ~0
    // for a TECH spending what it earns, so the 175 gantry needed its whole cost banked)
    // owner, 2026-10-25: the t3rush early check funds the gantry alone, not the gantry
    // plus its first T3 unit (played: "bank 4156/37400 metal" held the order 2-3 min past 175)
    bool FundsOpeningUnit() { return TechPlan::plan != "t3rush"; }
    bool Ready(CCircuitDef@ factory, CCircuitUnit@ builder) {
        if (builder is null || factory is null || !builder.circuitDef.CanBuild(factory)) return false;
        CCircuitDef@ reactor = ai.GetCircuitDef(TechChain::DefFor("afus"));
        const bool economy = reactor !is null && reactor.count > aiBuilderMgr.GetUnfinishedCount(reactor);
        const float power = builder is null ? 0.0f : builder.circuitDef.GetBuildSpeed();
        return GantryMath::CanStart(economy,
            metalWindow.Ready(ai.frame, Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND),
            metalWindow.Mean(), Global::RoleSettings::Tech::EarlyGantryMetalIncome,
            TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0,
            TechHeavyRush::Pending(), Funded(factory, FundsOpeningUnit(), true), power,
            Global::RoleSettings::Tech::GantryMinimumBuilderPower);
    }
    // What Funded() weighed, for a waiting line
    string FundingNote(CCircuitDef@ factory, bool includeOpeningUnit, bool grossIncome = false) {
        CCircuitDef@ opening = includeOpeningUnit ? OpeningUnit() : null;
        const float cost = factory.costM + (opening is null ? 0.0f : opening.costM);
        return "bank " + int(aiEconomyMgr.metal.current) + "/" + int(cost) + " metal, 10 s income "
            + int(Economy::GetMinMetalIncomeLast10s())
            + (grossIncome ? " (gross)" : " - usage " + int(TeamEconomy::OwnMetal(TeamEconomy::USAGE)))
            + ", energy " + int(Economy::GetMinEnergyIncomeLast10s()) + " - usage " + int(TeamEconomy::OwnEnergy(TeamEconomy::USAGE))
            + " + converters " + int(ai.GetTeamRulesParam("mmUse", 0.0f));
    }
    // The first of Ready()'s checks that fails, in its order (owner, 2026-10-24:
    // the early wait named no reason). Only for logging: Ready() decides.
    string ReadyWhy(CCircuitDef@ factory, CCircuitUnit@ builder) {
        if (builder is null || factory is null) return "no builder or gantry definition";
        if (!builder.circuitDef.CanBuild(factory)) return builder.circuitDef.GetName() + " cannot build " + factory.GetName();
        CCircuitDef@ reactor = ai.GetCircuitDef(TechChain::DefFor("afus"));
        if (reactor is null || reactor.count <= aiBuilderMgr.GetUnfinishedCount(reactor)) return "no finished advanced fusion";
        if (!metalWindow.Ready(ai.frame, Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND))
            return "income window not ready";
        if (metalWindow.Mean() < Global::RoleSettings::Tech::EarlyGantryMetalIncome)
            return "income " + int(metalWindow.Mean()) + " of " + int(Global::RoleSettings::Tech::EarlyGantryMetalIncome);
        if (TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0) return "a nuke commitment";
        if (TechHeavyRush::Pending()) return "a heavy rush pending";
        if (!Funded(factory, FundsOpeningUnit(), true)) return "funding (" + FundingNote(factory, FundsOpeningUnit(), true) + ")";
        if (builder.circuitDef.GetBuildSpeed() < Global::RoleSettings::Tech::GantryMinimumBuilderPower)
            return builder.circuitDef.GetName() + " build power " + int(builder.circuitDef.GetBuildSpeed())
                + " under " + int(Global::RoleSettings::Tech::GantryMinimumBuilderPower);
        return "ready";
    }
    bool ReachableBattlefield(const AIFloat3& in position, int facing) {
        CCircuitDef@ opening = OpeningUnit();
        if (opening is null) return false;
        const AIFloat3 exit = position + Layout::Fwd(facing) * Global::RoleSettings::Tech::GantryExitProbeDistance;
        // Connected movement-area lookup, not Dijkstra per placement candidate.
        // Existing Fits/IsExitClear still validate factory footprint and exit.
        return aiTerrainMgr.CanTraverse(opening, exit, Lanes::Front());
    }
    bool SafeWorker(CCircuitUnit@ builder, const AIFloat3& in position) {
        return builder !is null && aiBattle.SurfThreat(position) <= Global::RoleSettings::Tech::GantryMaximumSurfaceThreat
            && aiTerrainMgr.CanReachAtSafe(builder, position, builder.circuitDef.GetBuildDistance());
    }
    void Waiting(const string& in reason) {
        if (ai.frame < nextLogFrame) return;
        nextLogFrame = ai.frame + Global::RoleSettings::Tech::GantryLogIntervalSeconds * SECOND;
        GenericHelpers::LogUtil("[TECH][Gantry] " + reason, 1);
    }
    // The single reason the last Work() returned null (D-288 evidence: a
    // 35-minute run stalled on "no site/cap/cooldown/safe worker" without
    // saying which). Written only on a null path, read by TechGantryScale's
    // waiting line and INV-199; never per frame.
    string why = "none";
    IUnitTask@ Null(const string& in reason) { why = reason; return null; }
    string Threat(const AIFloat3& in position) {
        return "threat " + aiBattle.SurfThreat(position) + " of " + Global::RoleSettings::Tech::GantryMaximumSurfaceThreat;
    }
    string Unsafe(CCircuitUnit@ builder, const AIFloat3& in position, const string& in what) {
        return what + " unsafe for " + builder.circuitDef.GetName() + " " + builder.id + " (" + Threat(position)
            + (aiTerrainMgr.CanReachAtSafe(builder, position, builder.circuitDef.GetBuildDistance()) ? ", reachable)" : ", unreachable)");
    }
    bool EarlyComplete() {
        if (!EarlyEnabled() || earlyDeferred) return true;
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        return definition !is null && definition.count > aiBuilderMgr.GetUnfinishedCount(definition);
    }
    IUnitTask@ EarlyWork(CCircuitUnit@ builder) {
        if (EarlyComplete()) return null;
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        if (definition is null) return null;
        // Once the cluster is committed, its own progress/recovery owns the
        // task. Funding fluctuations never abandon a real construction frame.
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry(definition.GetName());
        // The attempt clock starts once the gantry is admissible (a cluster, or
        // Ready), not at the advanced fusion (played 2026-10-24: income reached
        // 175 at 12:38 and the window opened at 10:55 had expired by 14:23)
        if (earlyStartFrame < 0 && (cluster !is null || Ready(definition, builder))) earlyStartFrame = ai.frame;
        bool committed = false;
        int progressFrame = earlyStartFrame;
        if (cluster !is null) {
            CCircuitUnit@ factory = TechFactories::LabAt(cluster);
            committed = factory !is null || (cluster.labTask !is null && !cluster.labTask.IsDead());
            bool supportFrame = false, supportWorker = false;
            SupportHolds(cluster, supportFrame, supportWorker);
            committed = committed || supportFrame || supportWorker;
            progressFrame = AiMax(progressFrame, cluster.gantryProgressFrame);
        }
        if (!committed && progressFrame >= 0
            && ai.frame - progressFrame >= Global::RoleSettings::Tech::EarlyGantryAttemptSeconds * SECOND) {
            earlyDeferred = true;
            Waiting("early admission expired; continuing normal air/economy sequence");
            return null;
        }
        if (cluster !is null) return Work(TechFactories::ReadyCluster(cluster), definition, builder);
        // owner, 2026-10-26: only a builder that can build the gantry opens it or names the wait
        // (played: the commander and T1 constructors ask most often, so the 30 s line only ever
        // said "corcom cannot build corgant" and hid the real reason)
        if (!builder.circuitDef.CanBuild(definition)) return null;
        if (!Ready(definition, builder)) { Waiting("waiting: " + ReadyWhy(definition, builder)); return null; }
        @cluster = TechFactories::ReadyCluster(TechFactories::OpenCluster(definition, TechFactories::MayPlan(definition), true));
        if (cluster is null) { Waiting("waiting for a safe reachable cluster/cap/cooldown"); return null; }
        return Work(cluster, definition, builder);
    }

    // Owner (2026-10-11, back on 2026-10-18): the t3rush gantry's cluster, the
    // first gantry cluster TECH plans on that plan, gets a random
    // T3RushTurretsMin..T3RushTurretsMax turrets while its gantry goes up (the
    // first TurretsBeforeLab before the order, the rest beside the frame), then
    // from the frame the gantry stands climbs evenly over T3RushTurretsRampSeconds
    // to T3RushTurretsRampTo. Several turret orders at once (SupportOrder).
    TechFactories::Cluster@ t3Cluster;
    int t3Turrets = -1;
    int t3RampStart = -1;
    int T3RushTurretTarget(TechFactories::Cluster@ cluster, CCircuitUnit@ factory) {
        if (TechPlan::plan != "t3rush" || Global::RoleSettings::Tech::T3RushTurretsMax <= 0
            || cluster is null || cluster.ahead || cluster.tier < 3) return 0;
        // a given-up cluster (ahead again, ground released) hands the roll to its replacement
        if (t3Cluster is null || (t3Cluster !is cluster && (t3Cluster.ahead || t3Cluster.labRes < 0))) {
            @t3Cluster = cluster; t3RampStart = -1;
        }
        if (cluster !is t3Cluster) return 0;
        if (t3Turrets < 0) {
            const int lo = AiMax(1, Global::RoleSettings::Tech::T3RushTurretsMin);
            const int hi = AiMax(lo, Global::RoleSettings::Tech::T3RushTurretsMax);
            t3Turrets = AiMax(lo, AiMin(hi, AiRandom(lo, hi)));
            GenericHelpers::LogUtil("[TECH][T3Rush] the gantry cluster gets " + t3Turrets + " turrets while the gantry goes up (block "
                + cluster.slots + ")", 1);
        }
        int cap = AiMin(t3Turrets, cluster.slots);
        const int ramp = Global::RoleSettings::Tech::T3RushTurretsRampSeconds;
        const int top = AiMin(Global::RoleSettings::Tech::T3RushTurretsRampTo, cluster.slots);
        if (ramp > 0 && top > cap && factory !is null && factory.GetBuildProgress() >= 1.0f) {
            if (t3RampStart < 0) {
                t3RampStart = ai.frame;
                GenericHelpers::LogUtil("[TECH][T3Rush] the gantry stands: its turrets climb from " + cap + " to " + top
                    + " over " + ramp + " s", 1);
            }
            const float k = AiMin(1.0f, float(ai.frame - t3RampStart) / float(ramp * SECOND));
            cap += int(float(top - cap) * k);
        }
        return cap;
    }
    IUnitTask@ T3RushTurret(TechFactories::Cluster@ cluster, CCircuitUnit@ builder, CCircuitUnit@ factory) {
        const int want = T3RushTurretTarget(cluster, factory);
        if (want <= 0 || builder is null) return null;
        string why;
        return SupportOrder(cluster, builder, TechFactories::Nano(), want, "t3rush gantry turret (of " + want + ")", why);
    }

    // The gantry block's turret orders (owner, 2026-10-24). The construction
    // aircraft (corca and the like) are the block's builders: there are many of
    // them, so up to GantrySupportParallel orders go out at once, each pinned to
    // its own slot. Nothing here keeps a unit handle across frames: a worker
    // killed on its way leaves its task with no units, and the next capable
    // builder that asks takes the task over. Dead tasks are pruned on every ask.
    void SupportForget(TechFactories::Cluster@ cluster, uint index) {
        cluster.supportTasks.removeAt(index);
        cluster.supportSlots.removeAt(index);
        cluster.supportFrames.removeAt(index);
    }
    // Drops dead orders and returns the live ones. An order that died with no
    // turret on its slot rests the slot GantrySupportSlotRestSeconds, and after
    // GantrySupportSlotMaxFails such deaths the slot is released (played
    // 2026-10-24: 157 orders on one slot that never framed, one every 8 frames).
    int PruneSupport(TechFactories::Cluster@ cluster) {
        int live = 0;
        for (int index = int(cluster.supportTasks.length()) - 1; index >= 0; --index) {
            IUnitTask@ task = cluster.supportTasks[index];
            if (task !is null && !task.IsDead()) { ++live; continue; }
            const int slot = cluster.supportSlots[index];
            SupportForget(cluster, uint(index));
            if (slot < 0 || aiTerrainMgr.GetReservationState(slot) != 0) continue;   // consumed (built) or held by another order
            const string key = "" + slot;
            int64 fails = 0;   // dictionary integers are int64: an int out never matches (played: a slot released on its first death)
            cluster.supportSlotFails.get(key, fails);
            ++fails;
            cluster.supportSlotFails.set(key, fails);
            cluster.supportSlotRest.set(key, int64(ai.frame + Global::RoleSettings::Tech::GantrySupportSlotRestSeconds * SECOND));
            if (fails >= Global::RoleSettings::Tech::GantrySupportSlotMaxFails) {
                aiTerrainMgr.ReleaseReservation(slot);
                GenericHelpers::LogUtil("[TECH][Gantry] turret slot " + slot + " given up: " + fails + " orders died there with no frame", 1);
            }
        }
        return live;
    }
    // What holds the missing-turret fallback: a turret frame of the block, or an
    // order whose worker is on its way for under GantrySupportNoFrameSeconds
    void SupportHolds(TechFactories::Cluster@ cluster, bool &out frame, bool &out worker) {
        frame = false; worker = false;
        for (uint index = 0; index < cluster.supportTasks.length(); ++index) {
            IBuilderTask@ task = cast<IBuilderTask>(cluster.supportTasks[index]);
            if (task is null || task.IsDead()) continue;
            if (task.target !is null) { frame = true; continue; }
            if (task.GetUnits().length() > 0
                && ai.frame - cluster.supportFrames[index] < Global::RoleSettings::Tech::GantrySupportNoFrameSeconds * SECOND) worker = true;
        }
        // Only this cluster's recorded slots count: a neighbour's progressing
        // turret must not hold our zero-turret recovery indefinitely.
        for (uint index = 0; index < cluster.turretPos.length() && !frame; ++index) {
            CCircuitUnit@ candidate = TechFactories::TurretAt(cluster.turretPos[index]);
            if (candidate !is null && candidate.GetBuildProgress() < 1.0f) frame = true;
        }
    }
    bool OwnsSupport(TechFactories::Cluster@ cluster, IBuilderTask@ task) {
        for (uint index = 0; index < cluster.supportTasks.length(); ++index)
            if (task is cluster.supportTasks[index]) return true;
        return false;
    }
    // The next turret work for `builder` on the block, `want` turrets in all
    // (standing or ordered): an order left without a worker, a turret frame, or
    // a new order. `why` says why there is none.
    IUnitTask@ SupportOrder(TechFactories::Cluster@ cluster, CCircuitUnit@ builder, CCircuitDef@ turret, int want,
        const string& in what, string &out why) {
        why = "";
        if (cluster is null || builder is null || turret is null) { why = "no cluster, builder or turret definition"; return null; }
        if (!builder.circuitDef.CanBuild(turret)) { why = builder.circuitDef.GetName() + " cannot build the turret"; return null; }
        const int live = PruneSupport(cluster);
        // 1. an order whose worker is gone (killed or moved on): this builder takes it over
        for (uint index = 0; index < cluster.supportTasks.length(); ++index) {
            IBuilderTask@ task = cast<IBuilderTask>(cluster.supportTasks[index]);
            if (task is null || task.IsDead() || task.GetUnits().length() > 0) continue;
            if (SafeWorker(builder, task.GetBuildPos())) return cluster.supportTasks[index];
        }
        // 2. a turret frame of the block; an unsafe/unreachable one belongs to
        // recovery, never a duplicate turret
        for (uint index = 0; index < cluster.turretPos.length(); ++index) {
            CCircuitUnit@ frame = TechFactories::TurretAt(cluster.turretPos[index]);
            if (frame is null || frame.GetBuildProgress() >= 1.0f) continue;
            if (!SafeWorker(builder, frame.GetPos(ai.frame))) { why = Unsafe(builder, frame.GetPos(ai.frame), "turret frame " + frame.id); continue; }
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame,
                Global::RoleSettings::Tech::GantryAssistSeconds * SECOND));
        }
        // 3. a new order
        if (live >= AiMax(1, Global::RoleSettings::Tech::GantrySupportParallel)) { why = "" + live + " turret orders in flight"; return null; }
        if (TechFactories::TurretsOf(cluster) + live >= want) { why = "the block's " + want + " turrets stand or are ordered"; return null; }
        if (Layout::TurretsCapped()) { why = "turret cap: " + Layout::TurretsInFlight() + " in flight"; return null; }
        const int slot = aiTerrainMgr.NextSlotAny(cluster.nanoGroup, builder.GetPos(ai.frame));
        if (slot < 0) { why = "no free turret slot in group " + cluster.nanoGroup; return null; }
        int64 rest = 0;
        if (cluster.supportSlotRest.get("" + slot, rest) && ai.frame < rest) {
            why = "turret slot " + slot + " rests " + int((rest - ai.frame) / SECOND + 1) + " s after a lost order";
            return null;
        }
        const AIFloat3 position = aiTerrainMgr.GetReservationPos(slot);
        if (!SafeWorker(builder, position)) { why = Unsafe(builder, position, "turret slot " + slot); return null; }
        IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::NANO, turret, slot, what + ", " + (live + 1) + " in flight");
        if (task is null) { why = "turret slot " + slot + " refused (state " + aiTerrainMgr.GetReservationState(slot) + ")"; return null; }
        bool known = false;
        for (uint index = 0; index < cluster.turretPos.length(); ++index)
            if (MapHelpers::SqDist(position, cluster.turretPos[index]) < SQUARE_SIZE * SQUARE_SIZE) known = true;
        if (!known) cluster.turretPos.insertLast(position);
        cluster.turretFrame = ai.frame; cluster.started = true;
        aiTerrainMgr.SetLayoutInt("tech.cluster." + cluster.labRes + ".started", 1);
        cluster.supportTasks.insertLast(task);
        cluster.supportSlots.insertLast(slot);
        cluster.supportFrames.insertLast(ai.frame);
        return task;
    }
    // owner, 2026-10-24: on the t3rush plan the first gantry is ordered once
    // funded, without its FrontT3TurretsFirst block standing first
    bool RushWithoutBlock(TechFactories::Cluster@ cluster, CCircuitDef@ definition) {
        return Global::RoleSettings::Tech::T3RushGantryWithoutTurrets && TechPlan::plan == "t3rush"
            && cluster !is null && cluster.tier >= 3 && definition !is null
            && definition.count <= aiBuilderMgr.GetUnfinishedCount(definition)   // no gantry of this kind stands yet
            && Funded(definition, false);
    }

    IUnitTask@ Work(TechFactories::Cluster@ cluster, CCircuitDef@ definition, CCircuitUnit@ builder) {
        if (cluster is null || definition is null || builder is null) return Null("no cluster, definition or builder");
        CCircuitUnit@ factory = TechFactories::LabAt(cluster);
        // Adopt a late frame before inspecting timeouts or pending task state.
        if (factory !is null) {
            IUnitTask@ extra = T3RushTurret(cluster, builder, factory);
            if (extra !is null) return extra;
            if (factory.GetBuildProgress() < 1.0f) {
                if (SafeWorker(builder, cluster.pos))
                    return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, factory,
                        Global::RoleSettings::Tech::GantryAssistSeconds * SECOND));
                return Null(Unsafe(builder, cluster.pos, "gantry frame " + factory.id));
            }
            return Null("gantry " + factory.id + " stands: nothing to do");
        }
        if (!SafeWorker(builder, cluster.pos)) return Null(Unsafe(builder, cluster.pos, "cluster site"));
        if (cluster.gantryProgressFrame < 0) cluster.gantryProgressFrame = ai.frame;
        const int completed = TechFactories::FinishedTurrets(cluster);
        if (completed > cluster.gantryCompletedTurrets) {
            cluster.gantryCompletedTurrets = completed; cluster.gantryProgressFrame = ai.frame;
        }
        CCircuitDef@ turret = TechFactories::Nano();
        if (turret is null) return Null("no construction turret definition");
        const int block = TechFactories::TurretsBeforeLab(cluster);
        const bool rush = RushWithoutBlock(cluster, definition);
        const int required = rush ? 0 : block;
        const string progress = "turrets " + completed + "/" + block + " of " + cluster.slots + (rush ? " (t3rush: not waited for)" : "");
        const bool able = builder.circuitDef.CanBuild(definition)
            && builder.circuitDef.GetBuildSpeed() >= Global::RoleSettings::Tech::GantryMinimumBuilderPower;
        // D-364 (owner): a gantry the income step made due (one per
        // GantryScaleMetalStep) is ordered as soon as it is funded on that income and
        // this builder can build it; its turret block keeps filling behind it
        // (gantry.support, lab.front) and the turrets assist the frame. Played: the
        // T2 constructors that run gantry.scale cannot build the T1 turret, so the
        // ten-turret prerequisite fell to one T1 worker, and D-281's 90 s fallback
        // was held by that worker's order for eight minutes while the bank sat full
        // at +1,100 metal (3 of 10 turrets). The early D-281 cluster keeps its
        // turrets-first budget rule.
        const bool stepFunded = completed < required && !cluster.earlyGantry && able
            && Funded(definition, false, true);
        // The block's turrets: every builder that can build one (the construction
        // aircraft above all) drops them, several orders at once, until `block`
        // stand or are ordered. On a rush or a funded step a gantry builder goes to the gantry.
        string turretWhy = "";
        if (completed < block && !((rush || stepFunded) && able)) {
            IUnitTask@ task = SupportOrder(cluster, builder, turret, block, "gantry support turret", turretWhy);
            if (task !is null) return task;
        } else {
            PruneSupport(cluster);
        }
        bool fallback = false;
        if (completed < required && !stepFunded) {
            // D-281's funded fallback: GantryTurretWaitSeconds without turret
            // progress, no frame or worker on its way (under
            // GantrySupportNoFrameSeconds) holding the block, the gantry funded
            // and this builder able to build it
            bool supportFrame = false, supportWorker = false;
            SupportHolds(cluster, supportFrame, supportWorker);
            const bool funded = Funded(definition, false);
            const int waited = (ai.frame - cluster.gantryProgressFrame) / SECOND;
            fallback = GantryMath::CanFallback(ai.frame, cluster.gantryProgressFrame,
                Global::RoleSettings::Tech::GantryTurretWaitSeconds * SECOND, supportFrame, supportWorker, funded, able);
            if (!fallback) {
                string hold = waited < Global::RoleSettings::Tech::GantryTurretWaitSeconds
                    ? "fallback in " + (Global::RoleSettings::Tech::GantryTurretWaitSeconds - waited) + " s"
                    : (supportFrame ? "fallback held by a turret frame" : supportWorker ? "fallback held by a support worker on its way"
                        : !funded ? "fallback not funded (" + FundingNote(definition, false) + ")"
                        : "fallback: " + builder.circuitDef.GetName() + " cannot build the gantry or is under " + int(Global::RoleSettings::Tech::GantryMinimumBuilderPower) + " build power");
                return Null(progress + ": " + turretWhy + "; " + hold);
            }
        }
        if (!builder.circuitDef.CanBuild(definition)) return Null(progress + " stand: " + builder.circuitDef.GetName() + " cannot build " + definition.GetName());
        if (cluster.labTask !is null && !cluster.labTask.IsDead()) {
            if (cluster.labTask.GetUnits().length() < uint(AiMax(1, Global::RoleSettings::Tech::GantryMaximumTaskBuilders))) return cluster.labTask;
            return Null("gantry order has its " + Global::RoleSettings::Tech::GantryMaximumTaskBuilders + " builders (ordered " + (ai.frame - cluster.orderedFrame) / SECOND + " s ago, no frame)");
        }
        @cluster.labTask = null;
        if (cluster.built) {
            cluster.labRes = aiTerrainMgr.ReserveBuilding(definition, cluster.pos, cluster.facing);
            if (cluster.labRes < 0) return Null("rebuild: the gantry's ground could not be re-reserved");
            cluster.built = false; cluster.labSeen = false;
        }
        if (!definition.IsAvailable(ai.frame)) return Null("gantry cap " + definition.maxThisUnit + " reached (count " + definition.count + ")");
        // The early phase rechecks funding at the actual order; support work
        // can have consumed the initial budget since cluster activation.
        if (cluster.earlyGantry && (!Funded(definition, FundsOpeningUnit(), true)
            || !ReachableBattlefield(cluster.pos, cluster.facing)
            || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending())) return Null("early admission: funding, battlefield path or a rush commitment");
        IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::FACTORY, definition,
            cluster.labRes, stepFunded ? "gantry (funded by the income step, " + completed + " of " + block + " turrets stand; D-364)"
                : fallback ? "gantry (funded missing-turret-builder fallback)"
                : completed < block ? "gantry (t3rush: its turrets go up beside the frame)" : "gantry (supported cluster)");
        if (task !is null) {
            @cluster.labTask = task; cluster.orderedFrame = ai.frame;
            cluster.gantryFallback = fallback || stepFunded || completed < block;   // INV-045: ordered short of its block on purpose
            return task;
        }
        return Null("gantry slot " + cluster.labRes + " refused (state " + aiTerrainMgr.GetReservationState(cluster.labRes) + ")");
    }
    // A budgeted gantry bootstrap is an explicit exception to discretionary
    // forward-builder recall. Match the live task/target, never a unit type or
    // an entire region. Used by both periodic and callback recall paths.
    bool OwnsWork(CCircuitUnit@ builder) {
        if (!RecoveryEnabled() || builder is null || builder.task is null) return false;
        IBuilderTask@ task = cast<IBuilderTask>(builder.task);
        if (task is null || task.IsDead()) return false;
        for (uint index = 0; index < TechFactories::clusters.length(); ++index) {
            TechFactories::Cluster@ cluster = TechFactories::clusters[index];
            if (cluster.ahead || cluster.tier < 3 || cluster.labRes < 0) continue;
            if (task is cluster.labTask || OwnsSupport(cluster, task)) return true;
            if (task.target !is null && task.target.GetBuildProgress() < 1.0f) {
                if (task.target.id == cluster.labId) return true;
                for (uint slot = 0; slot < cluster.turretPos.length(); ++slot)
                    if (MapHelpers::SqDist(task.target.GetPos(ai.frame), cluster.turretPos[slot])
                        < SQUARE_SIZE * SQUARE_SIZE) return true;
            }
        }
        return false;
    }
    // Event-time diagnostic provenance, O(clusters), no per-frame census.
    // The early phase deliberately permits this factory's existing production
    // before the ordinary +500 gate. Gifts and unrelated/rebuilt producers
    // cannot inherit its admission just by sharing a unit definition.
    bool IsAdmittedProduction(CCircuitUnit@ product) {
        if (!EarlyEnabled() || product is null || product.GetProducerId() < 0) return false;
        for (uint index = 0; index < TechFactories::clusters.length(); ++index) {
            TechFactories::Cluster@ cluster = TechFactories::clusters[index];
            if (GantryMath::AdmittedProduct(true, cluster.earlyGantry && cluster.tier >= 3,
                product.GetProducerId(), cluster.labId, product.GetProductionFrame(), cluster.orderedFrame)) return true;
        }
        return false;
    }
    IUnitTask@ SupportWork(CCircuitUnit@ builder) {
        // D-364: the heavy rush no longer holds the open gantry cluster's turrets either
        if (!RecoveryEnabled() || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0) return null;
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry();
        if (cluster is null) {
            // the t3rush gantry stands: its turrets keep climbing (owner, 2026-10-18)
            if (t3Cluster is null || t3Cluster.labRes < 0) return null;
            return T3RushTurret(t3Cluster, builder, TechFactories::LabAt(t3Cluster));
        }
        return Work(cluster, ai.GetCircuitDef(cluster.defName), builder);
    }
}

// D-287 (owner): Marauder-class units (armmar, corshiva, legjav) belong to the
// early T3 window - rushes and amphibious ambushes. After a latched "late"
// point the gantries build the terrain's heavy instead: the land heavy (Thor)
// on a land map, the amphibious heavy (Titan) when the start is land-locked or
// the survey found an assault beach front. TECH only; every gate is O(1) and
// reads cached state (no unit scan, no per-ask allocation).
namespace TechHeavyChoice {
    const string LateKey = "tech.heavy.late";
    const string MassOpenKey = "tech.heavy.mass.open";
    const string MassBaseKey = "tech.heavy.mass.base";
    const string MassClosedKey = "tech.heavy.mass.closed";
    int lateFrame = -1;          // persisted: the frame the late latch closed the Marauder window
    int rushAdmitUntil = -1;     // the t3rush opening (RoleTech::Tech_T3RushProduce) ordered a Marauder-class unit until this frame
    int massOpen = -1, massBase = 0, massClosed = -1;   // persisted: the optional single late mass batch
    bool loaded = false;
    array<string> cached;        // reused candidate list; rebuilt only when side or terrain changes
    string cachedSide;
    int cachedTerrain = -1;      // 0 land, 1 amphibious

    bool Enabled() {
        return Global::AISettings::Role == AiRole::TECH && Global::RoleSettings::Tech::HeavyChoiceEnabled;
    }
    void Load() {
        if (loaded) return;
        loaded = true;
        lateFrame = aiTerrainMgr.GetLayoutInt(LateKey, -1);
        massOpen = aiTerrainMgr.GetLayoutInt(MassOpenKey, -1);
        massBase = aiTerrainMgr.GetLayoutInt(MassBaseKey, 0);
        massClosed = aiTerrainMgr.GetLayoutInt(MassClosedKey, -1);
    }
    bool Late() {
        if (!Enabled()) return false;
        Load();
        return lateFrame >= 0;
    }
    // StrategicSites recomputes assaultBeaches only on a lane recalculation.
    bool Amphibious() {
        return Global::Map::LandLocked
            || StrategicSites::assaultBeaches >= Global::RoleSettings::Tech::HeavyAmphibiousMinBeaches;
    }
    string Terrain() { return Amphibious() ? "amphibious" : "land"; }
    bool IsMarauderClass(const string& in name) {
        return name == "armmar" || name == "corshiva" || name == "legjav";
    }
    // False only for a late TECH: AIR (which shares AmphibiousOps) is unchanged.
    bool MarauderAllowed() { return !Late(); }

    // 1 Hz from Tech_EconomyUpdate. O(1): one ring-buffer minimum read; does
    // nothing once latched (the latch never re-opens).
    void Tick() {
        if (!Enabled() || Late()) return;
        const bool byTime = ai.frame >= Global::RoleSettings::Tech::HeavyLateMinutes * MINUTE;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const bool byIncome = Economy::IncomeWindowReady() && mi >= Global::RoleSettings::Tech::HeavyLateMetalIncome;
        if (!byTime && !byIncome) return;
        lateFrame = ai.frame;
        aiTerrainMgr.SetLayoutInt(LateKey, lateFrame);
        GenericHelpers::LogUtil("[TECH][Heavy] late latched frame=" + ai.frame + " mi=" + int(mi)
            + " reason=" + (byTime ? "time" : "income") + " terrain=" + Terrain()
            + " assaultBeaches=" + StrategicSites::assaultBeaches + "; Marauder-class production closed", 1);
    }

    // Ordered candidates for this side and terrain: the preferred heavy, then
    // the other. Each must still pass the gantry's CanBuild and the cap (a map
    // cap such as armthor = 0 falls through to the next) in EnqueueGantryBatchFrom.
    array<string>@ Candidates(const string& in side) {
        const int terrain = Amphibious() ? 1 : 0;
        if (terrain != cachedTerrain || side != cachedSide) {
            cachedTerrain = terrain; cachedSide = side;
            string land = Global::RoleSettings::Tech::HeavyLandArmada, amph = Global::RoleSettings::Tech::HeavyAmphArmada;
            if (side == "cortex") { land = Global::RoleSettings::Tech::HeavyLandCortex; amph = Global::RoleSettings::Tech::HeavyAmphCortex; }
            else if (side == "legion") { land = Global::RoleSettings::Tech::HeavyLandLegion; amph = Global::RoleSettings::Tech::HeavyAmphLegion; }
            const string first = terrain == 1 ? amph : land, second = terrain == 1 ? land : amph;
            cached.resize(0);
            if (first.length() > 0) cached.insertLast(first);
            if (second.length() > 0 && second != first) cached.insertLast(second);
        }
        return @cached;
    }
    // HeavyAlternate (owner, 2026-10-22): every other batch starts with the other unit of the pair
    // (Thor, Titan, Thor ...), land and amphibious alike. The pair's second unit is still the
    // fallback when the first cannot be built. Candidates() itself stays unchanged: the transport
    // check reads it.
    array<string> alternated;    // reused ordering for LateBatch
    string lastBatchUnit;        // the unit the last successful late batch built
    array<string>@ BatchOrder(const string& in side) {
        array<string>@ c = Candidates(side);
        if (!Global::RoleSettings::Tech::HeavyAlternate || c.length() < 2 || lastBatchUnit != c[0]) return @c;
        alternated.resize(0);
        for (uint i = 1; i < c.length(); ++i) alternated.insertLast(c[i]);
        alternated.insertLast(c[0]);
        return @alternated;
    }
    // One level-1 line per batch (one batch per gantry ask, five units each).
    IUnitTask@ LateBatch(CCircuitUnit@ gantry, const string& in side, int count) {
        IUnitTask@ task = Factory::EnqueueGantryBatchFrom(gantry, BatchOrder(side), count, Task::Priority::HIGH);
        if (task !is null) lastBatchUnit = Factory::lastGantryBatchUnit;
        if (task !is null)
            GenericHelpers::LogUtil("[TECH][Heavy] batch side=" + side + " terrain=" + Terrain()
                + " unit=" + Factory::lastGantryBatchUnit + " gantry=" + gantry.circuitDef.GetName() + " x" + count, 1);
        return task;
    }

    // The owner's "very large numbers" exception, off by default
    // (LateMarauderMassBatch = 0): once, on an amphibious map, a late batch of N
    // Marauders. Returns the recruit limit for AmphibiousOps::Produce, 0 = none.
    // Losses before the batch completes are refilled (the base is the count at
    // opening); the window closes for good once the count reaches the limit.
    int MassBatchLimit(CCircuitDef@ marauder) {
        const int mass = Global::RoleSettings::Tech::LateMarauderMassBatch;
        if (marauder is null || mass <= 0) return 0;
        Load();
        if (massClosed >= 0 || !Amphibious()) return 0;
        if (massOpen < 0) {
            massOpen = ai.frame; massBase = marauder.count;
            aiTerrainMgr.SetLayoutInt(MassOpenKey, massOpen);
            aiTerrainMgr.SetLayoutInt(MassBaseKey, massBase);
            GenericHelpers::LogUtil("[TECH][Heavy] late Marauder mass batch opened n=" + mass + " base=" + massBase, 1);
        }
        const int limit = massBase + mass;
        if (marauder.count >= limit) {
            massClosed = ai.frame;
            aiTerrainMgr.SetLayoutInt(MassClosedKey, massClosed);
            GenericHelpers::LogUtil("[TECH][Heavy] late Marauder mass batch closed count=" + marauder.count, 1);
            return 0;
        }
        return limit;
    }
    bool MassAdmitted(int created) {
        return massOpen >= 0 && created >= massOpen && (massClosed < 0 || created <= massClosed);
    }

    // INV-198, event time from Invariants::OnUnitAdded: O(1) per unit added,
    // the gantry lookup only for a Marauder-class unit after the latch.
    void CheckProduct(CCircuitUnit@ unit) {
        if (unit is null || unit.circuitDef is null || !Late()) return;
        const string name = unit.circuitDef.GetName();
        if (!IsMarauderClass(name) || unit.GetProducerId() < 0) return;   // gifts have no local producer
        CCircuitUnit@ producer = ai.GetTeamUnit(unit.GetProducerId());
        if (producer is null || producer.circuitDef is null || !UnitHelpers::IsGantryLab(producer.circuitDef.GetName())) return;
        const int created = unit.GetProductionFrame();
        // Started inside the early window, or a recruit enqueued before the
        // latch that the factory picked up just after it (no recruit is
        // cancelled at the latch; one factory pass is well under 30 s).
        if (created >= 0 && created < lateFrame + 30 * SECOND) return;
        if (MassAdmitted(created)) return;
        if (created >= 0 && created <= rushAdmitUntil) return;   // owner, 2026-10-25: the t3rush opening goes first, latch or not
        Invariants::Violation("INV-198", name, "late TECH gantry " + producer.circuitDef.GetName() + " produced Marauder-class "
            + name + " " + unit.id + " created=" + created + " late=" + lateFrame);
    }
}

// D-288 (owner): the first gantry at GantryScaleFirstMetal (t3rush:
// GantryScaleFirstMetalT3Rush), then one more per further GantryScaleMetalStep.
// The single owner of TECH's gantry target, cap and due flag; rule
// gantry.scale and the legacy T2 rung only read Due(). Every other gantry path
// (D-281 early gantry, chain steps, cluster recovery) counts toward Have().
namespace TechGantryScale {
    const string TargetKey = "tech.gantry.target";
    int highWater = 0;           // persisted target: floor(income / step), capped, never lowered
    bool loaded = false, due = false, capRaised = false;
    int have = 0, mapCeiling = -1;
    int dueSince = -1, progressFrame = -1, lastHave = -1, lastOpen = -1, lastTurretProgress = -1;
    int lastLogTarget = -1, lastLogHave = -1;
    bool lastLogDue = false;
    string lastReason = "none";
    CCircuitDef@ landDef;
    CCircuitDef@ waterDef;

    bool Enabled() {
        return Global::AISettings::Role == AiRole::TECH && Global::RoleSettings::Tech::GantryScaleEnabled;
    }
    void Load() {
        if (loaded) return;
        loaded = true;
        highWater = AiMax(0, aiTerrainMgr.GetLayoutInt(TargetKey, 0));
        const string side = Global::AISettings::Side;
        @landDef = ai.GetCircuitDef(UnitHelpers::GetLandGantryForSide(side));
        @waterDef = ai.GetCircuitDef(side == "cortex" ? "corgantuw" : (side == "legion" ? "leggantuw" : "armshltxuw"));
        // A map limit on the gantry is a ceiling this policy never raises past.
        int cap = -1;
        if (landDef !is null && Global::Map::MergedUnitLimits.get(landDef.GetName(), cap)) mapCeiling = cap;
    }
    bool Due() { return Enabled() && due; }

    // The first gantry's income: GantryScaleFirstMetal, or on the t3rush plan
    // GantryScaleFirstMetalT3Rush (owner, 2026-10-22) (0 = the step), never
    // above the step.
    float FirstMetal(float step) {
        const float first = TechPlan::plan == "t3rush" ? Global::RoleSettings::Tech::GantryScaleFirstMetalT3Rush
            : Global::RoleSettings::Tech::GantryScaleFirstMetal;
        if (first <= 0.0f) return step;
        return AiMin(first, step);
    }

    // Standing gantries and frames (def.count counts frames), plus land orders
    // not framed yet. O(clusters); the cluster list is a few tiers x a few
    // clusters (well under 20), script reads only.
    int Have(int &out openClusters, int &out turretProgress) {
        int n = (landDef is null ? 0 : landDef.count) + (waterDef is null ? 0 : waterDef.count);
        int ordered = 0;
        openClusters = 0; turretProgress = -1;
        for (uint i = 0; i < TechFactories::clusters.length(); ++i) {
            TechFactories::Cluster@ c = TechFactories::clusters[i];
            if (c.ahead || c.tier < 3 || c.labRes < 0) continue;
            ++openClusters;
            turretProgress = AiMax(turretProgress, c.gantryProgressFrame);
            if (c.labTask is null || c.labTask.IsDead()) continue;
            IBuilderTask@ order = cast<IBuilderTask>(c.labTask);
            if (order !is null && order.target is null) ++ordered;
        }
        // A legacy (layout off) order: Builder's flag, with no frame of it yet
        if (ordered == 0 && Builder::LandGantryQueuedCount > 0 && landDef !is null
            && aiBuilderMgr.GetUnfinishedCount(landDef) == 0) ordered = 1;
        return n + ordered;
    }
    // Event-driven in effect: writes only when the wanted cap is above the
    // current one (the target rose, or a load restored it). Water gantries
    // stay TechHarbour's (D-121): counted in Have(), their cap untouched.
    void RaiseCaps() {
        int wanted = highWater;
        if (mapCeiling >= 0) wanted = AiMin(wanted, mapCeiling);
        if (landDef is null || landDef.maxThisUnit >= wanted) return;
        if (capRaised)
            Invariants::Violation("INV-199", "cap", landDef.GetName() + " cap " + landDef.maxThisUnit
                + " fell below the gantry target " + wanted + " (another writer lowered it)");
        landDef.maxThisUnit = wanted;
        capRaised = true;
    }

    // 1 Hz from Tech_EconomyUpdate. O(clusters) + O(1) economy reads.
    void Tick() {
        if (!Enabled()) { due = false; return; }
        Load();
        if (landDef is null || !Economy::IncomeWindowReady()) { due = false; return; }
        const float mi = Economy::GetMinMetalIncomeLast10s();   // 10 s minimum: a spike never raises the target
        const float step = AiMax(1.0f, Global::RoleSettings::Tech::GantryScaleMetalStep);
        // Owner (2026-10-19, t3rush 2026-10-22): the first gantry at FirstMetal()
        const float first = FirstMetal(step);
        const int raw = AiMin(AiMax(0, Global::RoleSettings::Tech::GantryScaleMax), AiMax(int(mi / step), mi >= first ? 1 : 0));
        if (raw > highWater) {
            highWater = raw;
            aiTerrainMgr.SetLayoutInt(TargetKey, highWater);
        }
        RaiseCaps();
        int openClusters = 0, turretProgress = -1;
        have = Have(openClusters, turretProgress);
        // Progress for INV-199: a gantry framed/lost, a cluster opened, a turret finished
        if (have != lastHave || openClusters != lastOpen || turretProgress > lastTurretProgress) progressFrame = ai.frame;
        lastHave = have; lastOpen = openClusters; lastTurretProgress = AiMax(lastTurretProgress, turretProgress);
        const bool energyOk = Global::RoleSettings::Tech::GantryScaleEnergyFloor <= 0.0f
            || Economy::GetMinEnergyIncomeLast10s() >= Global::RoleSettings::Tech::GantryScaleEnergyFloor;
        // D-364: only the nuke commitment blocks the step gantry (the chain on its
        // silo, then the bounded first-stockpile window). The heavy rush used to
        // block it too, and its finite batch waits for FRONT recipients it may never
        // get: played, a T3-plan TECH with the heavy strategy rolled sat at a full
        // bank from +560 to +600 metal for twenty minutes, `blocked=rush`, no gantry.
        const bool blocked = TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0;
        // Hysteresis: the high-water target never cancels work; a new order also
        // needs the income to hold (have + 1) x step x share right now.
        // A map limit on the gantry is the ceiling of what can be due.
        const int target = mapCeiling >= 0 ? AiMin(highWater, mapCeiling) : highWater;
        const bool newDue = have < target && energyOk && !blocked
            && mi >= (have == 0 ? first : float(have + 1) * step) * Global::RoleSettings::Tech::GantryScaleDropShare;
        if (newDue && !due) { dueSince = ai.frame; progressFrame = ai.frame; }
        due = newDue;
        if (highWater != lastLogTarget || have != lastLogHave || due != lastLogDue) {
            lastLogTarget = highWater; lastLogHave = have; lastLogDue = due;
            GenericHelpers::LogUtil("[TECH][GantryScale] target=" + highWater + " have=" + have + " mi=" + int(mi)
                + " cap=" + landDef.maxThisUnit + " due=" + (due ? 1 : 0)
                + (blocked ? " blocked=rush" : "") + (energyOk ? "" : " blocked=energy"), 1);
        }
    }

    // The act of rule gantry.scale (and the legacy T2 rung): the front T3
    // cluster through TechFactories::Route (MayPlan: cap + 120 s gantry
    // cooldown, failed-search memo), else the legacy placement with the layout
    // off. The cluster's turrets and order are TechGantry::Work's.
    int nextLogFrame = 0;   // own limiter: must not starve TechGantry::Waiting's early-gantry lines
    // The team's unit count against its engine limit. Only on a null path about
    // to be logged (30 s) or reported (INV-199): GetOwnedUnitIds allocates an
    // array of N ids, never per ask or per frame. Played evidence (D-288): a
    // fixture-economy run sat at 1838 of its limit from 27 min, no structure
    // of ours finished after that, and the gantry cluster could not frame.
    string UnitBudget() {
        const int limit = aiEconomyMgr.GetEffectiveUnitLimit();
        const int units = ai.GetOwnedUnitIds().length();
        return "units " + units + "/" + limit + (limit > 0 && units >= limit - 2 ? " UNIT LIMIT" : "");
    }
    IUnitTask@ Work(CCircuitUnit@ builder) {
        if (!Due() || builder is null || landDef is null) return null;
        bool routed = false;
        TechGantry::why = "none";
        IUnitTask@ task = TechFactories::Route(landDef.GetName(), builder, routed);
        if (task !is null) return task;
        if (routed) {
            // Route found or opened a cluster and TechGantry::Work refused:
            // its reason. No cluster at all: the cap, the 120 s gantry
            // cooldown (MayPlan) or no site between the front shares.
            if (TechGantry::why != "none") lastReason = TechGantry::why;
            else if (TechFactories::ExistingGantry(landDef.GetName()) !is null) lastReason = "cluster not ready (relocating a blocked slot)";
            else if (!landDef.IsAvailable(ai.frame)) lastReason = "gantry cap " + landDef.maxThisUnit + " reached (count " + landDef.count + ")";
            else if (!Builder::IsGantryOffCooldown()) lastReason = "gantry cooldown";
            else lastReason = "no cluster site (TechFactories::Plan found no spot)";
        } else {
            @task = Builder::EnqueueLandGantry(Global::AISettings::Side);
            if (task !is null) return task;
            lastReason = !Builder::IsGantryOffCooldown() ? "legacy placement: gantry cooldown"
                : !landDef.IsAvailable(ai.frame) ? "legacy placement: gantry cap " + landDef.maxThisUnit + " reached" : "legacy placement refused";
        }
        if (ai.frame >= nextLogFrame) {
            nextLogFrame = ai.frame + Global::RoleSettings::Tech::GantryLogIntervalSeconds * SECOND;
            GenericHelpers::LogUtil("[TECH][GantryScale] waiting: " + lastReason + " (have=" + have + " target=" + highWater
                + " builder=" + builder.circuitDef.GetName() + " " + builder.id + ", " + UnitBudget() + ")", 1);
        }
        return null;
    }

    // INV-199 from Invariants::Tick (1 Hz), O(1) until the grace expires;
    // the violation line names the single blocking reason and the unit budget.
    void Check() {
        if (!Due()) return;
        const int since = AiMax(dueSince, progressFrame);
        if (ai.frame - since > Global::RoleSettings::Tech::GantryScaleGraceSeconds * SECOND)
            Invariants::Violation("INV-199", "due", "gantry due " + ((ai.frame - since) / SECOND) + " s without progress: have="
                + have + " target=" + highWater + " cap=" + landDef.maxThisUnit + " " + UnitBudget() + " last=" + lastReason);
    }
}
