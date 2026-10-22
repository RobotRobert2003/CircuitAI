// Controlled late-game factory fixture, not a natural economy benchmark.
namespace SupportAssistProbe {
    bool active = false;
    bool checked = false;
    void Tick() {
        if (!active || ai.teamId != 0) return;
        SupportBuild::transitioned = true;
        SupportBuild::donationResolved = true;
        SupportBuild::economyReady = true;
        SupportProduction::ApplyLimits();
        SupportProduction::VerifyLimits();
        TechBuild::metalFullSince = 0;
        Economy::_UpdateSlidingMinima(ai.frame, 200.0f, 20000.0f);
        if (checked || ai.frame < MINUTE) return;
        checked = true;
        bool valid = true;
        for (uint index = 0; index < SupportProduction::decoys.length(); ++index) {
            CCircuitDef@ definition = SupportProduction::decoys[index];
            valid = valid && definition.maxThisUnit == 0 && !definition.IsAvailable(ai.frame);
        }
        const string assistant = UnitHelpers::GetFastAssistBots(Global::AISettings::Side)[0];
        const string lab = UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side);
        FactoryProduction::FactoryConfig@ configuration;
        valid = valid && FactoryProduction::factoryConfigs.get(lab, @configuration) && configuration !is null;
        if (configuration !is null) {
            for (uint index = 0; index < configuration.roles.length(); ++index)
                valid = valid && configuration.GetUnitsForRole(configuration.roles[index]).find(assistant) < 0;
        }
        CCircuitDef@ definition = ai.GetCircuitDef(assistant);
        const int original = definition.maxThisUnit;
        Global::Map::MergedUnitLimits.set(assistant, 1);
        SupportProduction::ApplyLimits();
        valid = valid && definition.maxThisUnit == 1;
        Global::Map::MergedUnitLimits.delete(assistant);
        SupportProduction::ApplyLimits();
        valid = valid && definition.maxThisUnit == original;
        GenericHelpers::LogUtil("[SupportAssistTest] " + (valid ? "PASS" : "FAIL") + " caps_roster_and_map_limit", 1);
    }
    bool Handle(const string& in message) {
        if (message != "support-assist-probe|setup") return false;
        active = true;
        TechChain::active = false;
        TechChain::done = true;
        Global::RoleSettings::Support::MaxFastAssistBots = 2;
        SupportProduction::ApplyLimits();
        GenericHelpers::LogUtil("[SupportAssistTest] setup role=" + int(Global::AISettings::Role), 1);
        return true;
    }
}
