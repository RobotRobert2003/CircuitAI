#include "../../global.as"
#include "../../helpers/math/heavy_rush_math.as"
#include "../../systems/team/donation.as"
#include "tech_heavy_delivery.as"

// A finite production obligation, independent of SPAM_RUSH. Only one lab and
// one recruit task belong to this controller. Existing economy update cadence
// services a bounded gift ledger; no per-frame army census or command resend.
namespace TechHeavyRush {
    const string StateKey = "tech.heavy.";
    int completed = 0;
    int targetCount = -1;
    int labId = -1;
    int orderedFrame = -1;
    IUnitTask@ recruit;
    int nextTrace = 0;
    int nextGift = 0;
    int engineUnitLimit = 0;
    int priorProductionLimit = -1;

    bool Selected() {
        return Global::AISettings::Role == AiRole::TECH
            && Global::RoleSettings::Tech::HeavyRushEnabled
            && Global::RoleSettings::Tech::HasStrategy(Strategy::T2_RUSH);
    }
    int TargetCount() {
        // O(1) cached read in production/retirement predicates. Persist before
        // enqueueing so role reinitialization cannot reroll an active batch.
        // Only the first selected rush consumes RNG; fixed bounds consume none.
        if (targetCount < 0) {
            targetCount = aiTerrainMgr.GetLayoutInt(StateKey + "target-count", -1);
            if (targetCount < 0) {
                const int minimumCount = AiMax(1, Global::RoleSettings::Tech::HeavyRushCountMin);
                const int maximumCount = AiMax(minimumCount, Global::RoleSettings::Tech::HeavyRushCountMax);
                targetCount = minimumCount == maximumCount ? minimumCount : AiRandom(minimumCount, maximumCount);
                aiTerrainMgr.SetLayoutInt(StateKey + "target-count", targetCount);
                GenericHelpers::LogUtil("[TECH][HeavyRush] target=" + targetCount
                    + " bounds=" + minimumCount + "-" + maximumCount, 1);
            }
        }
        return targetCount;
    }
    bool Pending() { return Selected() && completed < TargetCount(); }
    void Init() {
        completed = aiTerrainMgr.GetLayoutInt(StateKey + "completed", 0);
        targetCount = aiTerrainMgr.GetLayoutInt(StateKey + "target-count", -1);
        if (Selected()) TargetCount();
        labId = aiTerrainMgr.GetLayoutInt(StateKey + "lab", -1);
        orderedFrame = aiTerrainMgr.GetLayoutInt(StateKey + "ordered", -1);
        nextGift = aiTerrainMgr.GetLayoutInt(StateKey + "next-gift", 0);
        priorProductionLimit = aiTerrainMgr.GetLayoutInt(StateKey + "production-limit", -1);
        @recruit = null;
        CCircuitDef@ definition = ai.GetCircuitDef(UnitName());
        engineUnitLimit = aiTerrainMgr.GetLayoutInt(StateKey + "unit-limit", -1);
        if (engineUnitLimit < 0) {
            engineUnitLimit = definition is null ? 0 : definition.maxThisUnit;
            aiTerrainMgr.SetLayoutInt(StateKey + "unit-limit", engineUnitLimit);
        }
    }
    bool SiloReady() {
        if (TechPlan::Choose() != "nuke" && !TechChain::NukeRush()) return true;
        if (aiTerrainMgr.GetLayoutInt(StateKey + "silo-completed", 0) != 0) return true;
        CCircuitDef@ silo = ai.GetCircuitDef(TechChain::DefFor("silo"));
        const bool ready = silo !is null && silo.count - aiBuilderMgr.GetUnfinishedCount(silo) > 0;
        if (ready) aiTerrainMgr.SetLayoutInt(StateKey + "silo-completed", 1);
        return ready;
    }
    bool ProtectLab(int id) {
        // Before selecting a producer, retain the primary lab for this batch.
        // The nuke-specific refund caller explicitly overrides this protection.
        return Pending() && (labId < 0 || id == labId);
    }
    string UnitName() {
        string name;
        if (!Global::RoleSettings::Tech::HeavyRushUnits.get(Global::AISettings::Side, name)) return "";
        return name;
    }
    int Recipient() {
        array<Team::Roster::Entry@>@ allies = Team::Roster::WithRole(AiRole::FRONT);
        int best = -1;
        float distance = 1e30f;
        const AIFloat3 front = Lanes::Front();
        for (uint i = 0; i < allies.length(); ++i) {
            Team::Roster::Entry@ entry = allies[i];
            if (entry is null || entry.teamId == ai.teamId) continue;
            const AIFloat3 anchor = Team::Roster::DeliveryAnchor(entry);
            if (anchor.x < 0.0f) continue;
            const float candidate = MapHelpers::SqDist(front, anchor);
            if (candidate < distance || (candidate == distance && entry.teamId < best)) {
                distance = candidate; best = entry.teamId;
            }
        }
        return best;
    }
    void Blocked(const string& in reason) {
        if (ai.frame < nextTrace) return;
        nextTrace = ai.frame + 30 * SECOND;
        GenericHelpers::LogUtil("[TECH][HeavyRush] waiting: " + reason + "; completed=" + completed, 1);
    }
    bool RequiresFusion() {
        CCircuitDef@ fusion = ai.GetCircuitDef(TechChain::DefFor("fusion"));
        const int completedFusions = fusion is null ? 0 : fusion.count - aiBuilderMgr.GetUnfinishedCount(fusion);
        return HeavyRushMath::RequiresFusion(Pending(), completedFusions, LocalGeothermal::Output(),
            Global::RoleSettings::Tech::HeavyRushStableEnergy);
    }
    bool Affordable(CCircuitDef@ definition) {
        if (!SiloReady()) { Blocked("completed silo"); return false; }
        if (RequiresFusion()) { Blocked("stable fusion/geothermal power"); return false; }
        if (!MetalEconomy::Active()) {
            const AIFloat3 mex = Economy::MexTracker::GetNearestNonUpgradedMexInRange(
                Global::Map::StartPos, Global::Map::StartPos, Global::RoleSettings::Tech::OpeningMexRadius);
            if (mex.x >= 0.0f) { Blocked("home mex upgrades"); return false; }
        }
        const float horizon = Global::RoleSettings::Tech::HeavyRushBudgetSeconds;
        const float share = Global::RoleSettings::Tech::HeavyRushIncomeShare;
        const float converterUsage = ai.GetTeamRulesParam("mmUse", 0.0f);
        float usage = TeamEconomy::OwnEnergy(TeamEconomy::USAGE);
        // Keep the original first-missile funding priority. Outside that
        // window, admit against actual non-converter consumption, not the
        // hypothetical pull of all idle/underfunded construction power.
        if (TechChain::nukeFundingSilo >= 0) usage = AiMax(usage, aiEconomyMgr.energy.pull);
        const float availableEnergy = HeavyRushMath::AvailableEnergy(aiEconomyMgr.energy.income,
            usage, converterUsage, Global::RoleSettings::Tech::HeavyRushEnergyMargin);
        const float metalIncome = Economy::GetMinMetalIncomeLast10s();
        const bool funded = HeavyRushMath::CanFund(definition.costM, definition.costE,
            metalIncome, availableEnergy, aiEconomyMgr.metal.current, aiEconomyMgr.energy.current,
            horizon, share, Global::RoleSettings::Tech::HeavyRushMetalIncome);
        if (!funded) Blocked("income/energy budget");
        return funded;
    }
    IUnitTask@ Produce(CCircuitUnit@ factory) {
        if (AiPerfEnabled) AiPerfBeginLabel("tech-heavy-production");
        IUnitTask@ result = ProduceImpl(factory);
        if (AiPerfEnabled) AiPerfEndLabel();
        return result;
    }
    IUnitTask@ ProduceImpl(CCircuitUnit@ factory) {
        if (!Pending() || factory is null || !UnitHelpers::IsT2BotLab(factory.circuitDef.GetName())) return null;
        if (labId >= 0 && ai.GetTeamUnit(labId) is null) labId = -1;
        if (labId < 0) {
            labId = factory.id;
            aiTerrainMgr.SetLayoutInt(StateKey + "lab", labId);
        }
        if (factory.id != labId) return null;
        // Preserve the existing high-bank constructor expansion before taking
        // the lab for combat. This is bounded by T2BotConstructorCap, unlike
        // discretionary fast-assist production whose target grows with income.
        const int builderCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
        if (aiEconomyMgr.metal.storage > 0.0f
            && aiEconomyMgr.metal.current > aiEconomyMgr.metal.storage * Global::RoleSettings::Tech::T2ConstructorBankShare
            && builderCount < Global::RoleSettings::Tech::T2BotConstructorCap) return null;
        // Essential own constructors precede the heavy batch, like requested
        // constructor donations handled by the factory adapter before this role.
        array<string> constructors = UnitHelpers::GetT2BotConstructors(Global::AISettings::Side);
        if (constructors.length() > 0) {
            CCircuitDef@ builder = ai.GetCircuitDef(constructors[0]);
            const int wanted = Global::RoleSettings::Tech::MinimumT2ConstructorBots;
            if (builder !is null && builder.count + aiFactoryMgr.GetPendingRecruitCount(builder) < wanted) {
                if (builder.maxThisUnit < wanted) builder.maxThisUnit = wanted;
                return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH,
                    builder, factory.GetPos(ai.frame), 64.f));
            }
        }
        CCircuitDef@ definition = ai.GetCircuitDef(UnitName());
        if (definition is null || !factory.circuitDef.CanBuild(definition) || Recipient() < 0 || engineUnitLimit <= 0) {
            Blocked("available heavy unit and FRONT recipient");
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        }
        if (recruit !is null && !recruit.IsDead()) return recruit;
        if (aiFactoryMgr.GetPendingRecruitCount(definition) > 0 || !Affordable(definition))
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        if (priorProductionLimit < 0) {
            priorProductionLimit = definition.maxThisUnit;
            aiTerrainMgr.SetLayoutInt(StateKey + "production-limit", priorProductionLimit);
        }
        if (definition.maxThisUnit <= definition.count) definition.maxThisUnit = AiMin(engineUnitLimit, definition.count + 1);
        if (!definition.IsAvailable(ai.frame)) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        @recruit = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL,
            definition, factory.GetPos(ai.frame), 64.f));
        if (recruit !is null) {
            orderedFrame = ai.frame;
            aiTerrainMgr.SetLayoutInt(StateKey + "ordered", orderedFrame);
            GenericHelpers::LogUtil("[TECH][HeavyRush] recruit " + UnitName() + " number=" + (completed + 1), 1);
        }
        return recruit;
    }
    bool IsBatchProduction(CCircuitUnit@ unit) {
        return Pending() && unit !is null && unit.circuitDef.GetName() == UnitName()
            && unit.GetProducerId() == labId && orderedFrame >= 0 && unit.GetProductionFrame() >= orderedFrame;
    }
    bool OnFinished(CCircuitUnit@ unit) {
        if (!IsBatchProduction(unit)) return false;
        // Persistent per-budget-slot identity survives donation and duplicate
        // callbacks. The ledger grows with configured batch size, not army size.
        for (int index = 0; index < completed; ++index)
            if (aiTerrainMgr.GetLayoutInt(StateKey + "gift." + index, -1) == unit.id) return true;
        aiTerrainMgr.SetLayoutInt(StateKey + "gift." + completed, unit.id);
        aiTerrainMgr.SetLayoutInt(StateKey + "sent." + completed, 0);
        TechHeavyDelivery::Record(completed, unit.id);
        ++completed;
        aiTerrainMgr.SetLayoutInt(StateKey + "completed", completed);
        // Release only the definition limit this finite controller borrowed.
        // Owned gifts still in flight do not justify another production slot.
        if (!Pending() && priorProductionLimit >= 0) {
            CCircuitDef@ definition = ai.GetCircuitDef(UnitName());
            if (definition !is null) definition.maxThisUnit = priorProductionLimit;
        }
        orderedFrame = -1;
        aiTerrainMgr.SetLayoutInt(StateKey + "ordered", -1);
        @recruit = null;
        GenericHelpers::LogUtil("[TECH][HeavyRush] completed " + completed + "/" + TargetCount(), 1);
        return true; // delivery is deferred past native UnitAdded assignment
    }
    void Tick() {
        if (!Selected() || (!Pending() && nextGift >= completed)) return;
        if (AiPerfEnabled) AiPerfBeginLabel("tech-heavy-delivery");
        DeliverPending();
        if (AiPerfEnabled) AiPerfEndLabel();
    }
    void DeliverPending() {
        for (int index = nextGift; index < completed; ++index) {
            if (aiTerrainMgr.GetLayoutInt(StateKey + "sent." + index, 0) != 0) continue;
            TechHeavyDelivery::Update(index, aiTerrainMgr.GetLayoutInt(StateKey + "gift." + index, -1));
        }
        while (nextGift < completed && aiTerrainMgr.GetLayoutInt(StateKey + "sent." + nextGift, 0) != 0) ++nextGift;
        aiTerrainMgr.SetLayoutInt(StateKey + "next-gift", nextGift);
    }
}
