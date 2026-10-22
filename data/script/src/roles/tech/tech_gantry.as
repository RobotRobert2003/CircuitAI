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
    bool Funded(CCircuitDef@ factory, bool includeOpeningUnit) {
        if (factory is null) return false;
        float metalCost = factory.costM, energyCost = factory.costE;
        if (includeOpeningUnit) {
            CCircuitDef@ opening = OpeningUnit();
            if (opening is null || !factory.CanBuild(opening)) return false;
            metalCost += opening.costM; energyCost += opening.costE;
        }
        const float metalIncome = AiMax(0.0f, Economy::GetMinMetalIncomeLast10s()
            - TeamEconomy::OwnMetal(TeamEconomy::USAGE));
        const float availableEnergy = HeavyRushMath::AvailableEnergy(
            Economy::GetMinEnergyIncomeLast10s(), TeamEconomy::OwnEnergy(TeamEconomy::USAGE),
            ai.GetTeamRulesParam("mmUse", 0.0f), Global::RoleSettings::Tech::GantryEnergyReserve);
        return HeavyRushMath::CanFund(metalCost, energyCost, metalIncome, availableEnergy,
            aiEconomyMgr.metal.current, aiEconomyMgr.energy.current,
            Global::RoleSettings::Tech::GantryFundingSeconds,
            Global::RoleSettings::Tech::GantryFundingShare, 0.0f);
    }
    bool Ready(CCircuitDef@ factory, CCircuitUnit@ builder) {
        if (builder is null || factory is null || !builder.circuitDef.CanBuild(factory)) return false;
        CCircuitDef@ reactor = ai.GetCircuitDef(TechChain::DefFor("afus"));
        const bool economy = reactor !is null && reactor.count > aiBuilderMgr.GetUnfinishedCount(reactor);
        const float power = builder is null ? 0.0f : builder.circuitDef.GetBuildSpeed();
        return GantryMath::CanStart(economy,
            metalWindow.Ready(ai.frame, Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND),
            metalWindow.Mean(), Global::RoleSettings::Tech::EarlyGantryMetalIncome,
            TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0,
            TechHeavyRush::Pending(), Funded(factory, true), power,
            Global::RoleSettings::Tech::GantryMinimumBuilderPower);
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
        if (earlyStartFrame < 0) earlyStartFrame = ai.frame;
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        if (definition is null) return null;
        // Once the cluster is committed, its own progress/recovery owns the
        // task. Funding fluctuations never abandon a real construction frame.
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry(definition.GetName());
        bool committed = false;
        int progressFrame = earlyStartFrame;
        if (cluster !is null) {
            CCircuitUnit@ factory = TechFactories::LabAt(cluster);
            committed = factory !is null || (cluster.labTask !is null && !cluster.labTask.IsDead());
            IBuilderTask@ support = cast<IBuilderTask>(cluster.gantrySupportTask);
            if (support !is null && !support.IsDead())
                committed = committed || support.target !is null || support.GetUnits().length() > 0;
            progressFrame = AiMax(progressFrame, cluster.gantryProgressFrame);
        }
        if (!committed && ai.frame - progressFrame >= Global::RoleSettings::Tech::EarlyGantryAttemptSeconds * SECOND) {
            earlyDeferred = true;
            Waiting("early admission expired; continuing normal air/economy sequence");
            return null;
        }
        if (cluster !is null) return Work(TechFactories::ReadyCluster(cluster), definition, builder);
        if (!Ready(definition, builder)) { Waiting("waiting for AFUS, income, funding or prior commitments"); return null; }
        @cluster = TechFactories::ReadyCluster(TechFactories::OpenCluster(definition, TechFactories::MayPlan(definition), true));
        if (cluster is null) { Waiting("waiting for a safe reachable cluster/cap/cooldown"); return null; }
        return Work(cluster, definition, builder);
    }

    IUnitTask@ Work(TechFactories::Cluster@ cluster, CCircuitDef@ definition, CCircuitUnit@ builder) {
        if (cluster is null || definition is null || builder is null) return Null("no cluster, definition or builder");
        CCircuitUnit@ factory = TechFactories::LabAt(cluster);
        // Adopt a late frame before inspecting timeouts or pending task state.
        if (factory !is null) {
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
        const int required = TechFactories::TurretsBeforeLab(cluster);
        const string progress = "turrets " + completed + "/" + required + " of " + cluster.slots;
        // One explicit bootstrap assignment at a time. Native owns command
        // retry/reassignment and its pinned reservation; travel/frame ownership
        // suppresses fallback without falsifying the progress clock. GetUnits
        // snapshots only assigned task workers: O(task workers + reserved
        // turret slots), not an army scan or a constant-time whole decision.
        IBuilderTask@ support = cast<IBuilderTask>(cluster.gantrySupportTask);
        bool supportFrame = false, supportWorker = false;
        if (support !is null && !support.IsDead()) {
            supportFrame = support.target !is null;
            supportWorker = support.GetUnits().length() > 0;
            if (builder.circuitDef.CanBuild(turret) && !supportWorker
                && SafeWorker(builder, support.GetBuildPos())) return support;
        } else { @cluster.gantrySupportTask = null; }
        // Only this cluster's recorded slots count: a neighbour's progressing
        // turret must not hold our zero-turret recovery indefinitely.
        CCircuitUnit@ frame = null;
        for (uint index = 0; index < cluster.turretPos.length(); ++index) {
            CCircuitUnit@ candidate = TechFactories::TurretAt(cluster.turretPos[index]);
            if (candidate !is null && candidate.GetBuildProgress() < 1.0f) { @frame = candidate; break; }
        }
        if (frame !is null) supportFrame = true;
        bool fallback = false;
        string turretWhy = "";
        if (completed < required) {
            if (frame !is null) {
                if (SafeWorker(builder, frame.GetPos(ai.frame)))
                    return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame,
                        Global::RoleSettings::Tech::GantryAssistSeconds * SECOND));
                // An existing but unsafe/unreachable frame belongs to recovery;
                // neither override SafeWorker nor create a duplicate turret.
                turretWhy = Unsafe(builder, frame.GetPos(ai.frame), "turret frame " + frame.id);
            } else if (!builder.circuitDef.CanBuild(turret)) {
                turretWhy = builder.circuitDef.GetName() + " cannot build the turret";
            } else if (cluster.gantrySupportTask !is null) {
                // The one bootstrap order is alive with no frame yet: its builder
                // holds it (native retries the command; the 120 s task timeout
                // releases a refused placement), or its site is unsafe for this builder
                turretWhy = supportWorker
                    ? "support order has its worker, no frame yet (" + (ai.frame - cluster.turretFrame) / SECOND + " s)"
                    : Unsafe(builder, support.GetBuildPos(), "unassigned support order's site");
            } else if (Layout::TurretsCapped()) {
                // OrderPinned refuses a NANO silently under the D-097 turret cap
                // (orders in flight anywhere, including ones the engine refuses)
                turretWhy = "turret cap: " + Layout::TurretsInFlight() + " in flight";
            } else {
                const int slot = aiTerrainMgr.NextSlotAny(cluster.nanoGroup, builder.GetPos(ai.frame));
                if (slot < 0) turretWhy = "no free turret slot in group " + cluster.nanoGroup;
                else if (!SafeWorker(builder, aiTerrainMgr.GetReservationPos(slot))) turretWhy = Unsafe(builder, aiTerrainMgr.GetReservationPos(slot), "turret slot " + slot);
                else {
                    IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::NANO, turret, slot, "gantry support turret");
                    if (task !is null) {
                        const AIFloat3 position = aiTerrainMgr.GetReservationPos(slot);
                        bool known = false;
                        for (uint index = 0; index < cluster.turretPos.length(); ++index)
                            if (MapHelpers::SqDist(position, cluster.turretPos[index]) < SQUARE_SIZE * SQUARE_SIZE) known = true;
                        if (!known) cluster.turretPos.insertLast(position);
                        cluster.turretFrame = ai.frame; cluster.started = true;
                        aiTerrainMgr.SetLayoutInt("tech.cluster." + cluster.labRes + ".started", 1);
                        @cluster.gantrySupportTask = task;
                        return task;
                    }
                    turretWhy = "turret slot " + slot + " refused (state " + aiTerrainMgr.GetReservationState(slot) + ")";
                }
            }
            // D-281's funded fallback: GantryTurretWaitSeconds without turret
            // progress, no frame or assigned worker holding the block, the
            // gantry funded and this builder able to build it
            const bool funded = Funded(definition, false);
            const bool able = builder.circuitDef.CanBuild(definition)
                && builder.circuitDef.GetBuildSpeed() >= Global::RoleSettings::Tech::GantryMinimumBuilderPower;
            const int waited = (ai.frame - cluster.gantryProgressFrame) / SECOND;
            fallback = GantryMath::CanFallback(ai.frame, cluster.gantryProgressFrame,
                Global::RoleSettings::Tech::GantryTurretWaitSeconds * SECOND, supportFrame, supportWorker, funded, able);
            if (!fallback) {
                string hold = waited < Global::RoleSettings::Tech::GantryTurretWaitSeconds
                    ? "fallback in " + (Global::RoleSettings::Tech::GantryTurretWaitSeconds - waited) + " s"
                    : (supportFrame ? "fallback held by a turret frame" : supportWorker ? "fallback held by the support worker"
                        : !funded ? "fallback not funded (bank " + int(aiEconomyMgr.metal.current) + "/" + int(definition.costM)
                            + " metal, 10 s income " + int(Economy::GetMinMetalIncomeLast10s()) + ", energy " + int(Economy::GetMinEnergyIncomeLast10s())
                            + " - usage " + int(TeamEconomy::OwnEnergy(TeamEconomy::USAGE)) + " + converters " + int(ai.GetTeamRulesParam("mmUse", 0.0f)) + ")"
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
        if (cluster.earlyGantry && (!Funded(definition, true)
            || !ReachableBattlefield(cluster.pos, cluster.facing)
            || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending())) return Null("early admission: funding, battlefield path or a rush commitment");
        IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::FACTORY, definition,
            cluster.labRes, fallback ? "gantry (funded missing-turret-builder fallback)" : "gantry (supported cluster)");
        if (task !is null) {
            @cluster.labTask = task; cluster.orderedFrame = ai.frame;
            cluster.gantryFallback = fallback;
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
            if (task is cluster.gantrySupportTask || task is cluster.labTask) return true;
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
        if (!RecoveryEnabled() || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending()) return null;
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry();
        if (cluster is null) return null;
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
    // One level-1 line per batch (one batch per gantry ask, five units each).
    IUnitTask@ LateBatch(CCircuitUnit@ gantry, const string& in side, int count) {
        IUnitTask@ task = Factory::EnqueueGantryBatchFrom(gantry, Candidates(side), count, Task::Priority::HIGH);
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
        Invariants::Violation("INV-198", name, "late TECH gantry " + producer.circuitDef.GetName() + " produced Marauder-class "
            + name + " " + unit.id + " created=" + created + " late=" + lateFrame);
    }
}

// D-288 (owner): a gantry by 500 metal per second, then one more per further
// 500. The single owner of TECH's gantry target, cap and due flag; rule
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
        const int raw = AiMin(AiMax(0, Global::RoleSettings::Tech::GantryScaleMax), int(mi / step));
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
        const bool blocked = TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending();
        // Hysteresis: the high-water target never cancels work; a new order also
        // needs the income to hold (have + 1) x step x share right now.
        // A map limit on the gantry is the ceiling of what can be due.
        const int target = mapCeiling >= 0 ? AiMin(highWater, mapCeiling) : highWater;
        const bool newDue = have < target && energyOk && !blocked
            && mi >= float(have + 1) * step * Global::RoleSettings::Tech::GantryScaleDropShare;
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
