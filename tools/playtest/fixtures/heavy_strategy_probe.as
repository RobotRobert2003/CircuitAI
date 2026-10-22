// Runs in the actual host, restores every mutated setting before gameplay.
namespace HeavyStrategyProbe {
    void Run() {
        const uint savedMask = Global::RoleSettings::Tech::StrategyMask;
        const string savedPlan = Global::RoleSettings::Tech::EndgamePlan;
        const AiRole savedRole = Global::AISettings::Role;
        const int savedCompleted = TechHeavyRush::completed;
        const int savedTarget = TechHeavyRush::targetCount;
        const int savedMinimum = Global::RoleSettings::Tech::HeavyRushCountMin;
        const int savedMaximum = Global::RoleSettings::Tech::HeavyRushCountMax;
        const int savedPersistentTarget = aiTerrainMgr.GetLayoutInt(TechHeavyRush::StateKey + "target-count", -1);
        const bool savedEnabled = Global::RoleSettings::Tech::HeavyRushEnabled;
        Global::RoleSettings::Tech::EndgamePlan = "auto";
        Global::RoleSettings::Tech::HeavyRushEnabled = true;
        Global::AISettings::Role = AiRole::TECH;
        TechHeavyRush::completed = 0;
        TechHeavyRush::targetCount = 3;
        bool passed = true;
        EcoPlanner::ConversionDecision@ outer = EcoPlanner::conversionDecision;
        EcoPlanner::BeginConversionDecision(null);
        EcoPlanner::ConversionDecision@ first = EcoPlanner::conversionDecision;
        first.read = true; first.headroom = 123.0f;
        EcoPlanner::BeginConversionDecision(null);
        if (EcoPlanner::conversionDecision is first || EcoPlanner::conversionDecision.read) passed = false;
        EcoPlanner::EndConversionDecision(first);
        if (EcoPlanner::conversionDecision !is first || first.headroom != 123.0f || !first.read) passed = false;
        EcoPlanner::EndConversionDecision(outer);
        EcoPlanner::BeginConversionDecision(null);
        if (EcoPlanner::conversionDecision !is first || first.read || first.headroom != 0.0f) passed = false;
        EcoPlanner::EndConversionDecision(outer);

        for (uint mask = 0; mask < 16; ++mask) {
            Global::RoleSettings::Tech::StrategyMask = mask;
            const string expected = (mask & 4) != 0 ? "nuke" : (mask & 1) != 0 ? "spamrush" : (mask & 2) != 0 ? "t3rush" : "eco";
            if (TechPlan::Choose() != expected || TechHeavyRush::Selected() != ((mask & 8) != 0)) passed = false;
            // Startup has neither completed fusion nor geothermal power.
            if (TechHeavyRush::RequiresFusion() != ((mask & 8) != 0)) passed = false;
        }
        Global::RoleSettings::Tech::StrategyMask = 8;
        for (int count = 3; count <= 5; ++count) {
            TechHeavyRush::targetCount = count;
            TechHeavyRush::completed = count - 1;
            if (!TechHeavyRush::Pending()) passed = false;
            TechHeavyRush::completed = count;
            if (TechHeavyRush::Pending() || TechHeavyRush::RequiresFusion()) passed = false;
        }
        // Fixed bounds exercise persistence without perturbing gameplay RNG.
        Global::RoleSettings::Tech::HeavyRushCountMin = 4;
        Global::RoleSettings::Tech::HeavyRushCountMax = 4;
        aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "target-count", -1);
        TechHeavyRush::targetCount = -1;
        if (TechHeavyRush::TargetCount() != 4) passed = false;
        Global::RoleSettings::Tech::HeavyRushCountMin = 8;
        Global::RoleSettings::Tech::HeavyRushCountMax = 9;
        TechHeavyRush::targetCount = -1;
        if (TechHeavyRush::TargetCount() != 4) passed = false;
        // Reversed bounds collapse at the valid minimum; nonpositive bounds
        // collapse at one. HeavyRushEnabled is the explicit off switch.
        for (int index = 0; index < 2; ++index) {
            Global::RoleSettings::Tech::HeavyRushCountMin = index == 0 ? 7 : 0;
            Global::RoleSettings::Tech::HeavyRushCountMax = index == 0 ? 3 : -1;
            aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "target-count", -1);
            TechHeavyRush::targetCount = -1;
            if (TechHeavyRush::TargetCount() != (index == 0 ? 7 : 1)) passed = false;
        }
        Global::AISettings::Role = AiRole::FRONT;
        if (TechHeavyRush::Selected()) passed = false;
        Global::RoleSettings::Tech::EndgamePlan = "t2rush";
        if (TechPlan::Choose() != "spamrush") passed = false;
        // D-286: continuation and silo history across every independent roll.
        const string previousPlan = TechPlan::plan;
        const int previousPhase = TechPlan::phase;
        const int previousAfus = aiTerrainMgr.GetLayoutInt("tech.heavy.afus-completed", 0);
        const int previousSilo = aiTerrainMgr.GetLayoutInt("tech.heavy.silo-completed", 0);
        Global::AISettings::Role = AiRole::TECH;
        Global::RoleSettings::Tech::EndgamePlan = "auto";
        TechHeavyRush::targetCount = 3;
        for (uint mask = 0; mask < 16; ++mask) {
            Global::RoleSettings::Tech::StrategyMask = mask;
            TechPlan::plan = TechPlan::Choose();
            TechPlan::phase = 0;
            TechHeavyRush::completed = 3;
            aiTerrainMgr.SetLayoutInt("tech.heavy.afus-completed", 0);
            aiTerrainMgr.SetLayoutInt("tech.heavy.silo-completed", 1);
            array<TechChain::Step@>@ next = TechPlan::NextPhase("heavy phase 0");
            if ((mask & 8) != 0 && (next.length() == 0 || next[0].key != "afus")) passed = false;
            for (uint index = 0; index < next.length(); ++index)
                if (next[index].key == "heavy" || next[index].key == "silo") passed = false;
            // The restored milestone cannot consume or omit the nuke's income phase.
            if ((mask & 4) != 0 && (next.length() == 0 || next[next.length()-1].key != "income")) passed = false;
            if (TechPlan::phase != 1 || TechHeavyRush::completed != 3) passed = false;
        }
        const array<string> overrides = {"nuke", "spamrush", "t2rush", "t3rush", "lrpc"};
        for (uint index = 0; index < overrides.length(); ++index) {
            Global::RoleSettings::Tech::EndgamePlan = overrides[index];
            if (TechPlan::Choose() != (overrides[index] == "t2rush" ? "spamrush" : overrides[index])) passed = false;
        }
        Global::RoleSettings::Tech::EndgamePlan = "auto";
        Global::RoleSettings::Tech::StrategyMask = 8;
        TechPlan::plan = "eco"; TechPlan::phase = 0;
        aiTerrainMgr.SetLayoutInt("tech.heavy.afus-completed", 1);
        if (TechPlan::NextPhase("heavy phase 0").length() != 0) passed = false;
        TechPlan::plan = previousPlan; TechPlan::phase = previousPhase;
        aiTerrainMgr.SetLayoutInt("tech.heavy.afus-completed", previousAfus);
        aiTerrainMgr.SetLayoutInt("tech.heavy.silo-completed", previousSilo);
        Global::RoleSettings::Tech::StrategyMask = savedMask;
        Global::RoleSettings::Tech::EndgamePlan = savedPlan;
        Global::AISettings::Role = savedRole;
        Global::RoleSettings::Tech::HeavyRushEnabled = savedEnabled;
        TechHeavyRush::completed = savedCompleted;
        TechHeavyRush::targetCount = savedTarget;
        Global::RoleSettings::Tech::HeavyRushCountMin = savedMinimum;
        Global::RoleSettings::Tech::HeavyRushCountMax = savedMaximum;
        aiTerrainMgr.SetLayoutInt(TechHeavyRush::StateKey + "target-count", savedPersistentTarget);
        GenericHelpers::LogUtil("[HeavyStrategyTest] " + (passed ? "PASS" : "FAIL") + " sixteen masks, 3-5 batch boundaries, saved target, bound normalization, role isolation, legacy alias, first-AFUS continuation, completed silo history", 1);
    }
}
