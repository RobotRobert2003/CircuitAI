// Membership only: completion, reach, position and task state are always read
// live by consumers. Native revision changes on create/death/gift/morph/load.
// Rebuild in original owned iteration order, preserving selection tie breaks.
namespace OwnedEconomy {
    bool initialized = false;
    uint revision = 0;
    string workerTargetName;
    array<Id> workers, extractors, geothermal;
    void Refresh() {
        const uint current = ai.GetOwnedUnitRevision();
        if (initialized && revision == current) return;
        initialized = true; revision = current;
        workers.resize(0); extractors.resize(0); geothermal.resize(0);
        array<Id>@ owned = ai.GetOwnedUnitIds();
        CCircuitDef@ workerTarget = workerTargetName.length() == 0 ? null : ai.GetCircuitDef(workerTargetName);
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(owned[index]);
            if (unit is null || unit.circuitDef is null) continue;
            const CCircuitDef@ definition = unit.circuitDef;
            if (workerTarget !is null && definition.IsMobile() && definition.CanBuild(workerTarget)) workers.insertLast(unit.id);
            if (definition.GetExtractsMetal() > 0) extractors.insertLast(unit.id);
            const string name = definition.GetName();
            if (name == "armgeo" || name == "armageo" || name == "corgeo" || name == "corageo"
                || name == "leggeo" || name == "legageo") geothermal.insertLast(unit.id);
        }
    }
    array<Id>@ Workers(const CCircuitDef@ target) {
        const string name = target is null ? "" : target.GetName();
        if (name != workerTargetName) { workerTargetName = name; initialized = false; }
        Refresh(); return workers;
    }
    array<Id>@ Extractors() { Refresh(); return extractors; }
    array<Id>@ Geothermal() { Refresh(); return geothermal; }
}
