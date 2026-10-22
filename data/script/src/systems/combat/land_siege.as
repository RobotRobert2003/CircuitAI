#include "../../helpers/math/land_siege_math.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../global.as"
#include "../../task.as"

namespace LandSiege {
    // Policy roster, not a new combat classification. These units retain their
    // existing controllers. Fixed K=6; counts cost O(K*Q), where Q is native
    // pending recruit tasks (the callback scans them). Only factory decisions
    // with a funded deficit pay this; no enemy/army scans or periodic orders.
    const array<string> Counters = {"cortrem", "corvroc", "armmerl", "legavroc", "cormort", "leghrk"};

    IUnitTask@ Produce(CCircuitUnit@ factory)
    {
        if (!Global::Military::LandSiegeEnabled || factory is null
            || Global::AISettings::Role != AiRole::FRONT
            || Global::Map::LandLocked) return null;
        const string name = factory.circuitDef.GetName();
        if (!UnitHelpers::IsT2BotLab(name) && !UnitHelpers::IsT2VehicleLab(name)) return null;
        const float income = Economy::GetMinMetalIncomeLast10s();
        if (income < Global::Military::LandSiegeMinMetal
            || Economy::GetMinEnergyIncomeLast10s() < Global::Military::LandSiegeMinEnergy) return null;
        const float enemyMetal = aiEnemyMgr.GetEnemyCost(Unit::Role::STATIC.type);
        const SResponseInfo@ response = aiMilitaryMgr.GetResponseInfo(Unit::Role::ARTY.type);
        const float factor = response is null ? 1 : AiMax(1.f, response.factor);
        const float budget = LandSiegeMath::Budget(income, Global::Military::LandSiegeMinMetal,
            Global::Military::LandSiegeFullMetal, enemyMetal, aiMilitaryMgr.armyCost,
            Global::Military::LandSiegeResponseRatio, Global::Military::LandSiegeEarlyShare,
            Global::Military::LandSiegeLateShare, factor);
        if (budget <= 0) return null;

        float committed = 0;
        array<CCircuitDef@> defs(Counters.length());
        array<int> counts(Counters.length());
        for (uint i = 0; i < Counters.length(); ++i) {
            @defs[i] = ai.GetCircuitDef(Counters[i]);
            if (defs[i] is null) continue;
            // Native pending excludes recruits which already have a live
            // frame; match AIR's count+pending contract, including other labs.
            counts[i] = defs[i].count + aiFactoryMgr.GetPendingRecruitCount(defs[i]);
            committed += counts[i] * defs[i].costM;
        }
        CCircuitDef@ choice = null;
        float best = -1;
        int beforeCount = 0;
        for (uint i = 0; i < defs.length(); ++i) {
            CCircuitDef@ d = defs[i];
            if (d is null || !factory.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame)) continue;
            // Same factory: alternate useful answers by invested metal, not
            // unit count. Tremor gets a modest area-bombardment preference;
            // rockets remain available to remove individual fortified targets.
            const float preference = d.GetName() == "cortrem" ? 1.5f : 1;
            const float score = preference / ((counts[i] + 1) * d.costM);
            if (score > best) { best = score; @choice = d; beforeCount = counts[i]; }
        }
        // Choose the desired mix BEFORE affordability. Otherwise cheap rockets
        // repeatedly consume each small budget increase and starve Tremors.
        // Falling through keeps normal combat/constructor production active.
        if (choice is null || !LandSiegeMath::CanAdd(budget, committed, choice.costM)) return null;
        IUnitTask@ task = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER,
            Task::Priority::NORMAL, choice, factory.GetPos(ai.frame), 64.f));
        if (task !is null) {
            // Enqueue is synchronous. The next factory must see this order in
            // the shared native recruit ledger, even before a frame exists.
            if (choice.count + aiFactoryMgr.GetPendingRecruitCount(choice) != beforeCount + 1)
                Invariants::Violation("INV-155", choice.GetName(), "land siege recruit missing or duplicated in projected count");
            GenericHelpers::LogUtil("[LandSiege] factory=" + name + " unit=" + choice.GetName()
                + " static=" + int(enemyMetal) + " budget=" + int(budget) + " committed=" + int(committed)
                + " income=" + int(income), 1);
        }
        return task;
    }
}
