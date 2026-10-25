// SUPPORT shares geometry and construction mechanisms with TECH, not its
// post-T2 strategy. One bounded sequence per builder ask; no global unit scan.
#include "../tech/tech.as"
#include "../../systems/production/factory_production.as"
#include "../../helpers/construction/owned_economy_helpers.as"
#include "support_production.as"
#include "../../systems/construction/front_reclaim.as"

namespace SupportBuild {
    bool transitioned = false;
    bool donationResolved = false;
    bool economyReady = false;
    int pendingGift = -1;
    int pendingRecipient = -1;
    int giftFrame = -1;
    int lastForwardOrder = -100000;
    int lastDeferredMexes = -1;

    AIFloat3 HomeUpgradePosition(CCircuitUnit@ worker, CCircuitDef@ advanced) {
        AIFloat3 result(-1.0f, 0.0f, -1.0f);
        if (advanced is null || !worker.circuitDef.CanBuild(advanced)) return result;
        const float radius = Global::RoleSettings::Support::HomeMexRadius;
        float nearest = 1e30f;
        array<Id>@ owned = OwnedEconomy::Extractors();
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ extractor = ai.GetTeamUnit(owned[index]);
            if (extractor is null || extractor.GetBuildProgress() < 1.0f
                || extractor.circuitDef.GetExtractsMetal() <= 0.0f
                || extractor.circuitDef.GetExtractsMetal() >= advanced.GetExtractsMetal()) continue;
            const AIFloat3 position = extractor.GetPos(ai.frame);
            const float distance = MapHelpers::SqDist(worker.GetPos(ai.frame), position);
            if (distance >= nearest || MapHelpers::SqDist(position, Global::Map::StartPos) > radius * radius
                || !aiTerrainMgr.CanUpgradeTerrain(advanced, position)
                || !aiTerrainMgr.CanReachAt(worker, position, worker.circuitDef.GetBuildDistance())) continue;
            nearest = distance;
            result = position;
        }
        return result;
    }

    IUnitTask@ ForwardDefence(CCircuitUnit@ worker) {
        if (!economyReady || UnitHelpers::GetConstructorTier(worker.circuitDef) < 2
            || Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Support::ForwardDefenceMetalIncome
            || aiEconomyMgr.isEnergyStalling || ai.frame - lastForwardOrder < Global::RoleSettings::Support::ForwardDefenceIntervalSeconds * SECOND
            || aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::DEFENCE), null) > 0) return null;
        AIFloat3 position = Lanes::Front();
        const float distance = position.distance2D(Global::Map::StartPos);
        if (distance <= Global::RoleSettings::Support::HomeDefenceRadius) return null;
        const float setback = Global::RoleSettings::Support::ForwardDefenceSetback / distance;
        position.x += (Global::Map::StartPos.x - position.x) * setback;
        position.z += (Global::Map::StartPos.z - position.z) * setback;
        if (!aiBattle.IsFriendlyLane(position)
            || !aiTerrainMgr.CanReachAt(worker, position, worker.circuitDef.GetBuildDistance())) return null;
        array<string>@ chain = PorcHelpers::DefaultChain(Global::AISettings::Side, false);
        array<string> basicBuilders = UnitHelpers::GetT1BotConstructors(Global::AISettings::Side);
        for (uint index = 0; index < chain.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(chain[index]);
            if (definition is null || definition.GetMaxRange() <= 0.0f || !worker.circuitDef.CanBuild(definition)
                || !definition.IsAvailable(ai.frame) || definition.count >= Global::RoleSettings::Support::ForwardDefenceCountPerType) continue;
            bool basic = false;
            for (uint builderIndex = 0; builderIndex < basicBuilders.length(); ++builderIndex) {
                CCircuitDef@ builder = ai.GetCircuitDef(basicBuilders[builderIndex]);
                if (builder !is null && builder.CanBuild(definition)) basic = true;
            }
            if (basic || definition.costM > aiEconomyMgr.metal.current
                || definition.costM > Economy::GetMinMetalIncomeLast10s() * Global::RoleSettings::Support::ForwardDefenceBudgetSeconds
                || !aiTerrainMgr.CanUpgradeTerrain(definition, position)) continue;
            IUnitTask@ task = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE,
                Task::Priority::NORMAL, definition, position, 0.0f));
            if (task !is null) {
                lastForwardOrder = ai.frame;
                GenericHelpers::LogUtil("[SUPPORT][Front] ordered " + definition.GetName(), 1);
            }
            return task;
        }
        return null;
    }

    int FrontRecipient() {
        array<Team::Roster::Entry@>@ allies = Team::Roster::WithRole(AiRole::FRONT);
        int recipient = -1;
        float nearest = 1e30f;
        for (uint index = 0; index < allies.length(); ++index) {
            Team::Roster::Entry@ ally = allies[index];
            if (ally.teamId == ai.teamId || !aiEconomyMgr.IsTeamAlive(ally.teamId) || ally.advancedConstructors > 0) continue;
            const float distance = MapHelpers::SqDist(Global::Map::StartPos, ally.startPos);
            if (distance < nearest || (distance == nearest && ally.teamId < recipient)) {
                nearest = distance;
                recipient = ally.teamId;
            }
        }
        return recipient;
    }

    bool HomeMexesReady() {
        if (!transitioned) return false;
        const float radius = Global::RoleSettings::Support::HomeMexRadius;
        CCircuitDef@ advanced = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(Global::AISettings::Side));
        if (advanced is null) return false;
        if (aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEXUP), advanced) > 0) return false;
        array<Id>@ owned = OwnedEconomy::Workers(advanced);
        array<CCircuitUnit@> workers;
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ worker = ai.GetTeamUnit(owned[index]);
            if (worker !is null && worker.GetBuildProgress() >= 1.0f && worker.circuitDef.IsMobile()
                && worker.circuitDef.CanBuild(advanced)) workers.insertLast(worker);
        }
        // No constructor is not evidence that all remaining mexes are blocked.
        if (workers.length() == 0) return false;
        int deferred = 0;
        @owned = OwnedEconomy::Extractors();
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(owned[index]);
            if (unit is null || unit.circuitDef.GetExtractsMetal() <= 0.0f
                || MapHelpers::SqDist(unit.GetPos(ai.frame), Global::Map::StartPos) > radius * radius) continue;
            if (unit.GetBuildProgress() < 1.0f) return false;
            if (unit.circuitDef.GetExtractsMetal() >= advanced.GetExtractsMetal()) continue;
            const AIFloat3 position = unit.GetPos(ai.frame);
            bool eligible = false;
            if (aiTerrainMgr.CanUpgradeTerrain(advanced, position)) {
                for (uint workerIndex = 0; workerIndex < workers.length(); ++workerIndex) {
                    CCircuitUnit@ worker = workers[workerIndex];
                    if (aiTerrainMgr.CanReachAt(worker, position, worker.circuitDef.GetBuildDistance())) {
                        eligible = true;
                        break;
                    }
                }
            }
            if (eligible) return false;
            ++deferred;
        }
        if (deferred != lastDeferredMexes && deferred > 0)
            GenericHelpers::LogUtil("[SUPPORT][Home] deferred unsafe/unreachable mexes=" + deferred + "; will reconsider", 1);
        lastDeferredMexes = deferred;
        return true;
    }

    void DeliverConstructor() {
        if (donationResolved || !transitioned) return;
        if (aiTerrainMgr.GetLayoutInt("support.gift", 0) != 0) { donationResolved = true; return; }
        if (pendingGift < 0) {
            pendingGift = aiTerrainMgr.GetLayoutInt("support.gift.pending", -1);
            pendingRecipient = aiTerrainMgr.GetLayoutInt("support.gift.recipient", -1);
            giftFrame = aiTerrainMgr.GetLayoutInt("support.gift.frame", -1);
        }
        if (pendingGift >= 0) {
            if (ai.GetFriendlyUnitTeam(pendingGift) == pendingRecipient) {
                donationResolved = true;
                aiTerrainMgr.SetLayoutInt("support.gift", pendingRecipient + 1);
                GenericHelpers::LogUtil("[SUPPORT][Gift] constructor=" + pendingGift + " recipient=" + pendingRecipient, 1);
                return;
            }
            if (ai.frame - giftFrame < Global::RoleSettings::Support::ConstructorGiftRetrySeconds * SECOND) return;
            GenericHelpers::LogUtil("[SUPPORT][Gift] transfer unconfirmed; reconsider recipient", 1);
            pendingGift = -1;
            aiTerrainMgr.SetLayoutInt("support.gift.pending", -1);
        }
        const int recipient = FrontRecipient();
        if (recipient < 0) {
            donationResolved = true;
            GenericHelpers::LogUtil("[SUPPORT][Gift] skipped: no unsupplied living FRONT recipient", 1);
            return;
        }
        array<Id>@ owned = ai.GetOwnedUnitIds();
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(owned[index]);
            if (unit is null || unit.GetBuildProgress() < 1.0f
                || !UnitHelpers::IsT2BotConstructor(unit.circuitDef.GetName())) continue;
            const int unitId = unit.id;
            pendingGift = unitId;
            pendingRecipient = recipient;
            giftFrame = ai.frame;
            aiTerrainMgr.SetLayoutInt("support.gift.pending", pendingGift);
            aiTerrainMgr.SetLayoutInt("support.gift.recipient", recipient);
            aiTerrainMgr.SetLayoutInt("support.gift.frame", giftFrame);
            array<CCircuitUnit@> gift(1);
            @gift[0] = unit;
            ai.GiveUnits(gift, recipient);
            return;
        }
    }

    void Init() {
        transitioned = false;
        donationResolved = false;
        economyReady = false;
        pendingGift = -1;
        pendingRecipient = -1;
        giftFrame = -1;
        lastForwardOrder = -100000;
        lastDeferredMexes = -1;
        TechBuild::throwawayDecided = false;
        TechBuild::throwawayLabId = -1;
        aiBuilderMgr.recoverConstruction = true;
        aiBuilderMgr.experimentalBuild = true;
        aiBuilderMgr.experimentalDirectRange = Global::RoleSettings::Tech::ExperimentalBuildDirectRange;
        aiBuilderMgr.experimentalSearchRadius = Global::RoleSettings::Tech::ExperimentalSearchRadius;
        aiEconomyMgr.assistNanoEnabled = false;
        aiEconomyMgr.reclEnergyEff = 0.0f;
        RoleTech::Opening::Init();
        Layout::Plan(Global::AISettings::Side, true);
        // Explicit objective: profile TECH strategy dice cannot change SUPPORT.
        TechChain::Init("t2");
        // Owner (2026-10-16): no wind or solar ordered while FrontReclaim takes them down (off unless
        // Support::ReclaimT1EnergyAfterFusion; Layout::OnRoleLeave clears it)
        @Global::energyAllowed = @FrontReclaim::EnergyAllowed;
        GenericHelpers::LogUtil("[SUPPORT][Build] shared layout and T2 opening enabled", 1);
    }

    void Tick() {
        if (TechChain::Active() && TechChain::objective != "t2")
            Invariants::Violation("INV-181", "support-opening", "SUPPORT inherited a non-T2 strategic rush");
        TechBuild::TrackMetal();
        TechChain::Tick();
        // Retire only the disposable opening lab; never retire SUPPORT's T2
        // combat factory to fund a reactor. All actors read Lifecycle state.
        if (TechBuild::T2Begun() && Factory::primaryT1BotLab !is null
            && !TechBuild::throwawayDecided) {
            TechBuild::throwawayDecided = true;
            TechBuild::throwawayLabId = Factory::primaryT1BotLab.id;
            Lifecycle::Retire(Factory::primaryT1BotLab, "SUPPORT T2 transition");
        }
        CCircuitDef@ advancedLab = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
        if (!transitioned && advancedLab !is null
            && advancedLab.count > aiBuilderMgr.GetUnfinishedCount(advancedLab)) {
            transitioned = true;
            GenericHelpers::LogUtil("[SUPPORT][Phase] T2 combat production online", 1);
        }
        DeliverConstructor();
        const bool ready = donationResolved && HomeMexesReady();
        if (ready && !economyReady) GenericHelpers::LogUtil("[SUPPORT][Phase] home upgrades complete; combat released", 1);
        economyReady = ready;
    }

    IUnitTask@ FactoryTask(CCircuitUnit@ unit) {
        SupportProduction::ApplyLimits();
        SupportProduction::VerifyLimits();
        if (!Global::RoleSettings::Support::ExperimentalBuild) return aiFactoryMgr.DefaultMakeTask(unit);
        if (unit is null || unit.circuitDef is null || Lifecycle::IsRetiring(unit)) return null;
        const string name = unit.circuitDef.GetName();
        if (!unit.circuitDef.IsMobile() && !UnitHelpers::IsT1BotLab(name) && !UnitHelpers::IsT2BotLab(name))
            return aiFactoryMgr.DefaultMakeTask(unit);
        const bool advanced = UnitHelpers::IsT2BotLab(name);
        array<string> constructors = advanced ? UnitHelpers::GetT2BotConstructors(Global::AISettings::Side)
            : UnitHelpers::GetT1BotConstructors(Global::AISettings::Side);
        const int wanted = advanced ? Global::RoleSettings::Support::MinimumT2Constructors
            : Global::RoleSettings::Support::OpeningT1Constructors;
        for (uint index = 0; index < constructors.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(constructors[index]);
            if (definition !is null && unit.circuitDef.CanBuild(definition)
                && definition.count + aiFactoryMgr.GetPendingRecruitCount(definition) < wanted
                && definition.IsAvailable(ai.frame))
                return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH,
                    definition, unit.GetPos(ai.frame), 64.0f));
        }
        if (!advanced && !transitioned) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        // Elapsed time cannot turn an unfinished home upgrade into completion.
        // Builder recovery handles failed work; production never steals its budget.
        if (advanced && (!donationResolved || !economyReady))
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        // Owner (2026-10-25): SUPPORT picks no units of its own; the profile's
        // factory.json / factory_leg.json weights choose (caps still apply).
        return aiFactoryMgr.DefaultMakeTask(unit);
    }

    // Owner (2026-10-25): every finished T2 factory gets T2FactoryTurrets construction
    // turrets, AIR's count for a T2 plant. Layout::NanoTask is TECH's placement (the box
    // slot nearest a standing lab) and its in-flight cap, so turrets go up a few at a time.
    // Cost per builder ask: one pass over the factory registry plus one team-unit scan per
    // T2 factory (GetStaticBuildPowerNear); SUPPORT owns one or two.
    int lastTurretLog = -100000;
    IUnitTask@ FactoryTurrets(CCircuitUnit@ worker) {
        const int wanted = Global::RoleSettings::Support::T2FactoryTurrets;
        if (wanted <= 0 || !transitioned || !donationResolved || aiEconomyMgr.isEnergyStalling) return null;
        CCircuitDef@ nano = TechFactories::Nano();
        if (nano is null || !worker.circuitDef.CanBuild(nano) || !nano.IsAvailable(ai.frame)) return null;
        if (Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Support::T2FactoryTurretMinMetalIncome
            || aiEconomyMgr.metal.current < nano.costM * Global::RoleSettings::Tech::EcoTurretBankFraction) return null;
        const float turretPower = nano.GetBuildSpeed() * float(SECOND);
        if (turretPower <= 0.0f) return null;
        int factories = 0, under = 0, least = wanted;
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint index = 0; keys !is null && index < keys.length(); ++index) {
            CCircuitUnit@ factory = null;
            if (!Factory::allFactories.get(keys[index], @factory) || factory is null || factory.circuitDef is null) continue;
            const string name = factory.circuitDef.GetName();
            if (!UnitHelpers::IsT2BotLab(name) && !UnitHelpers::IsT2VehicleLab(name)) continue;
            if (ai.GetTeamUnit(factory.id) is null || factory.GetBuildProgress() < 1.0f || Lifecycle::IsRetiring(factory)) continue;
            ++factories;
            const int standing = int(aiBuilderMgr.GetStaticBuildPowerNear(factory.GetPos(ai.frame),
                Global::RoleSettings::Tech::ExpLabBuildPowerReach) / turretPower + 0.5f);
            if (standing < wanted) ++under;
            least = AiMin(least, standing);
        }
        // Box slots can fall out of a lab's reach: the team-wide count bounds the total.
        if (under == 0 || nano.count >= wanted * factories + Global::RoleSettings::Support::T2FactoryTurretSpare) return null;
        IUnitTask@ task = Layout::NanoTask(worker, Task::Priority::NORMAL);
        if (task !is null && ai.frame - lastTurretLog > 30 * SECOND) {
            lastTurretLog = ai.frame;
            GenericHelpers::LogUtil("[SUPPORT][Turrets] ordered one: fewest at a T2 factory " + least + "/" + wanted
                + ", " + factories + " T2 factories, " + nano.count + " turrets", 1);
        }
        return task;
    }

    IUnitTask@ MakeTask(CCircuitUnit@ unit) {
        if (unit is null || unit.circuitDef is null) return null;
        if (Team::Ferry::IsGift(unit.id)) return Team::Ferry::GiftTask(unit);
        IUnitTask@ task = TechBuild::KeepCurrent(unit);
        if (task !is null) return task;
        if (!unit.circuitDef.IsMobile()) {
            @task = RoleTech::Tech_TurretAssist(unit);
            return task !is null ? task : TechBuild::Wait(3 * SECOND);
        }
        if (TechBuild::IntoT2()) {
            @task = TechBuild::ReclaimT1Lab(unit, Global::RoleSettings::Tech::ExpAssistRadius);
            if (task !is null) return task;
        }
        // Spend the first owned advanced worker's metal on nearby upgrades.
        // Geo remains the first large energy project, ahead of fusion.
        if (transitioned && donationResolved && !economyReady
            && UnitHelpers::GetConstructorTier(unit.circuitDef) >= 2 && !aiEconomyMgr.isEnergyStalling) {
            @task = aiBuilderMgr.FindQueuedTask(unit, int(Task::BuildType::MEXUP));
            if (task !is null) return task;
            CCircuitDef@ advanced = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(Global::AISettings::Side));
            // The historical tracker can retain an old donated/destroyed site.
            // Select the live owned extractor, not a stale remembered coordinate.
            const AIFloat3 position = HomeUpgradePosition(unit, advanced);
            if (advanced !is null && unit.circuitDef.CanBuild(advanced) && position.x >= 0.0f
                && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEXUP), advanced) < Global::RoleSettings::MexUpgradeMaxConcurrent
                && aiTerrainMgr.CanUpgradeTerrain(advanced, position)
                && aiTerrainMgr.CanReachAt(unit, position, unit.circuitDef.GetBuildDistance())) {
                @task = aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, advanced, position, -1));
                if (task !is null) GenericHelpers::LogUtil("[SUPPORT][Home] upgrade at " + int(position.x) + "," + int(position.z), 1);
                if (task !is null) return task;
            }
        }
        @task = LocalGeothermal::Work(unit);
        if (task !is null) return task;
        // Owner (2026-10-16): after a fusion, winds and solars come down, those round the factories first
        @task = FrontReclaim::Work(unit);
        if (task !is null) return task;
        @task = TechChain::Next(unit);
        if (task !is null) return task;
        if (!TechBuild::IntoT2() && Factory::primaryT1BotLab is null) {
            @task = TechBuild::StartFactory(unit);
            if (task !is null) return task;
        }
        @task = FactoryTurrets(unit);
        if (task !is null) return task;
        // Reuse the same measured economy state, priority calculation, slot
        // admission and pin/rollback as TECH. No native task is speculatively
        // enqueued before this decision (the old SUPPORT ladder did that).
        EcoPlanner::State@ state = EcoPlanner::Read(unit,
            Economy::GetMinMetalIncomeLast10s(), Economy::GetMinEnergyIncomeLast10s());
        state.allowConverters = !TechBuild::MetalFullLong();
        state.allowReactors = economyReady;
        if (economyReady) {
            @task = aiBuilderMgr.FindQueuedTask(unit, int(Task::BuildType::DEFENCE));
            if (task !is null) return task;
            @task = ForwardDefence(unit);
            if (task !is null) return task;
        }
        string reason;
        const string key = EcoPlanner::Decide(state, reason);
        if (key.length() > 0) {
            @task = EcoPlanner::Enqueue(key, unit);
            if (task !is null) return task;
        }
        @task = TechBuild::ExpandMex(unit, state.mIncome);
        if (task !is null) return task;
        @task = TechBuild::QueuedOrder(unit);
        if (task !is null) return task;
        @task = TechBuild::AssistAny(unit, Global::RoleSettings::Tech::EcoAssistRadius);
        if (task !is null) return task;
        CCircuitUnit@ factory = transitioned ? Factory::primaryT2BotLab : Factory::primaryT1BotLab;
        if (factory !is null && !Lifecycle::IsRetiring(factory) && factory.task !is null
            && factory.task.GetType() == int(Task::Type::FACTORY))
            return GuardHelpers::AssignWorkerGuard(unit, factory, Task::Priority::LOW, true, 20 * SECOND);
        return TechBuild::Wait(3 * SECOND);
    }
}
