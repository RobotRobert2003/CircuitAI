#include "../../helpers/math/assist_math.as"
#include "../../helpers/math/heavy_rush_math.as"

// SUPPORT owns these UnitDef handles for this AI's lifetime (never unit handles).
// Init rebuilds them on role entry. No army scan, new timer or command loop.
namespace SupportProduction {
    const array<string> DecoyNames = {"armdecom", "cordecom", "legdecom"};
    array<CCircuitDef@> assistants;
    array<CCircuitDef@> decoys;
    int combatBatches = 0;
    void CombatBatch() {
        combatBatches = AiMin(AiMax(1, Global::RoleSettings::Support::CombatBatchesPerFastAssist), combatBatches + 1);
    }

    int Limit(const string& in name, int configured) {
        int result = AiMax(0, configured);
        int mapLimit = -1;
        if (Global::Map::MergedUnitLimits.get(name, mapLimit) && mapLimit >= 0)
            result = AiMin(result, mapLimit);
        return result;
    }
    void ApplyLimits() {
        for (uint index = 0; index < decoys.length(); ++index)
            decoys[index].maxThisUnit = Limit(decoys[index].GetName(), Global::RoleSettings::Support::MaxDecoyCommanders);
        for (uint index = 0; index < assistants.length(); ++index)
            assistants[index].maxThisUnit = Limit(assistants[index].GetName(), Global::RoleSettings::Support::MaxFastAssistBots);
    }
    void Init() {
        assistants.resize(0);
        decoys.resize(0);
        combatBatches = 0;
        array<string>@ names = UnitHelpers::GetAllFastAssistBots();
        for (uint index = 0; index < names.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(names[index]);
            if (definition !is null) assistants.insertLast(definition);
        }
        for (uint index = 0; index < DecoyNames.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(DecoyNames[index]);
            if (definition !is null) decoys.insertLast(definition);
        }
        ApplyLimits();
    }
    void ConfigureCombat() {
        // The registry is private to this AI and rebuilt by Initialize on role
        // entry. Remove only assist bots from this instance's random combat
        // lottery; their one-at-a-time BUILDPOWER admission below owns them.
        // Startup O(roster entries * 3); no other role's tables are changed.
        array<string>@ factories = FactoryProduction::factoryConfigs.getKeys();
        for (uint factoryIndex = 0; factoryIndex < factories.length(); ++factoryIndex) {
            FactoryProduction::FactoryConfig@ configuration;
            if (!FactoryProduction::factoryConfigs.get(factories[factoryIndex], @configuration) || configuration is null) continue;
            for (uint roleIndex = 0; roleIndex < configuration.roles.length(); ++roleIndex) {
                const string role = configuration.roles[roleIndex];
                array<string> units = configuration.GetUnitsForRole(role);
                for (int index = int(units.length()) - 1; index >= 0; --index) {
                    for (uint assistantIndex = 0; assistantIndex < assistants.length(); ++assistantIndex) {
                        if (units[index] == assistants[assistantIndex].GetName()) { units.removeAt(index); break; }
                    }
                }
                configuration.unitsByRole.set(role, units);
            }
        }
    }
    IUnitTask@ AssistTask(CCircuitUnit@ factory) {
        // Existing definition counts include frames; pending is unstarted
        // native recruits only. Re-read per ask so simultaneous factories see
        // prior admissions. O(3) queries, independent of army/factory size.
        int owned = 0, pending = 0;
        for (uint index = 0; index < assistants.length(); ++index) {
            owned += assistants[index].count;
            pending += aiFactoryMgr.GetPendingRecruitCount(assistants[index]);
            // A framed worker is already counted but not yet useful: let it
            // finish before ordering another, without double-counting it.
            pending += aiBuilderMgr.GetUnfinishedCount(assistants[index]);
        }
        const float income = Economy::GetMinMetalIncomeLast10s();
        const float usage = TeamEconomy::OwnMetal(TeamEconomy::USAGE);
        const bool pressure = TechBuild::MetalAhead();
        const float horizon = Global::RoleSettings::Support::FastAssistFundingSeconds;
        const float effectiveIncome = pressure && horizon > 0.0f
            ? AiMax(income, aiEconomyMgr.metal.current / horizon) : income;
        const int target = AssistMath::TargetCount(effectiveIncome,
            Global::RoleSettings::Support::FastAssistMinimumMetalIncome,
            Global::RoleSettings::Support::FastAssistMetalIncomePerBot,
            Global::RoleSettings::Support::MaxFastAssistBots);
        if (!AssistMath::CanRecruit(owned, pending, target,
            combatBatches >= AiMax(1, Global::RoleSettings::Support::CombatBatchesPerFastAssist),
            income > usage, pressure, aiEconomyMgr.isEnergyStalling)) return null;
        const float availableEnergy = HeavyRushMath::AvailableEnergy(Economy::GetMinEnergyIncomeLast10s(),
            TeamEconomy::OwnEnergy(TeamEconomy::USAGE), ai.GetTeamRulesParam("mmUse", 0.0f),
            Global::RoleSettings::Support::FastAssistEnergyReserve);
        for (uint index = 0; index < assistants.length(); ++index) {
            CCircuitDef@ definition = assistants[index];
            if (!factory.circuitDef.CanBuild(definition) || !definition.IsAvailable(ai.frame)
                || definition.count + aiFactoryMgr.GetPendingRecruitCount(definition) >= definition.maxThisUnit) continue;
            if (!HeavyRushMath::CanFund(definition.costM, definition.costE, AiMax(0.0f, income - usage),
                availableEnergy, aiEconomyMgr.metal.current, aiEconomyMgr.energy.current, horizon,
                Global::RoleSettings::Support::FastAssistFundingShare, 0.0f)) continue;
            IUnitTask@ task = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,
                Task::Priority::NORMAL, definition, factory.GetPos(ai.frame), 64.0f));
            if (task !is null) {
                combatBatches = 0;
                GenericHelpers::LogUtil("[SUPPORT][BuildPower] ordered " + definition.GetName()
                    + " owned=" + owned + " target=" + target, 1);
            }
            return task;
        }
        return null;
    }
    void VerifyLimits() {
        // Check policy rather than living count: old units and gifts must not
        // be reclaimed just because SUPPORT now forbids recruiting decoys.
        for (uint index = 0; index < decoys.length(); ++index)
            if (decoys[index].maxThisUnit > Limit(decoys[index].GetName(), Global::RoleSettings::Support::MaxDecoyCommanders))
                Invariants::Violation("INV-191", decoys[index].GetName(), "SUPPORT decoy production cap bypassed");
    }
}
