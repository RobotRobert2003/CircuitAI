// SUPPORT owns these UnitDef handles for this AI's lifetime (never unit handles).
// Init rebuilds them on role entry. Caps only: factory.json picks the units.
namespace SupportProduction {
    const array<string> DecoyNames = {"armdecom", "cordecom", "legdecom"};
    array<CCircuitDef@> assistants;
    array<CCircuitDef@> decoys;

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
    void VerifyLimits() {
        // Check policy rather than living count: old units and gifts must not
        // be reclaimed just because SUPPORT now forbids recruiting decoys.
        for (uint index = 0; index < decoys.length(); ++index)
            if (decoys[index].maxThisUnit > Limit(decoys[index].GetName(), Global::RoleSettings::Support::MaxDecoyCommanders))
                Invariants::Violation("INV-191", decoys[index].GetName(), "SUPPORT decoy production cap bypassed");
    }
}
