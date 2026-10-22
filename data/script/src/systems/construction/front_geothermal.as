// FRONT claims safe reachable vents once the opening can fund construction.
// Keep one refcounted project until native completion/abort; never retain unit
// wrappers. Re-evaluating its travelling builder returns the same task without
// searching/allocating another vent task. A bounded crew shares native GEO
// ownership; the natural Forge acceptance run checks completed construction.
#include "../../helpers/math/geothermal_math.as"
namespace FrontGeothermal {
    IBuilderTask@ project;
    void Reset() { @project=null; }
    IUnitTask@ Work(CCircuitUnit@ worker) {
        if (!Global::RoleSettings::Front::GeothermalEnabled || worker is null
            || !worker.circuitDef.IsMobile() || aiFactoryMgr.GetFactoryCount()<1) return null;
        if (project !is null && project.IsDead()) @project=null;
        IBuilderTask@ current=cast<IBuilderTask>(worker.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()==int(Task::BuildType::GEO)) {
            if (project is null) @project=current;
            return current;
        }
        if (project !is null) {
            // GetUnits creates only the bounded project crew array, not an AI
            // worker census. Native path safety and abort remain authoritative.
            if (project.GetUnits().length()<Global::RoleSettings::Front::GeothermalBuilders
                && project.buildDef !is null && worker.circuitDef.CanBuild(project.buildDef)
                && aiTerrainMgr.CanReachAtSafe(worker,project.GetBuildPos(),worker.circuitDef.GetBuildDistance()))
                return project;
            return null;
        }
        const float income=Economy::GetMinEnergyIncomeLast10s();
        if (income<Global::RoleSettings::Front::GeothermalBootstrapEnergy) return null;
        IUnitTask@ pending=aiBuilderMgr.FindQueuedTask(worker,int(Task::BuildType::GEO));
        if (pending !is null) { @project=cast<IBuilderTask>(pending); return pending; }
        // A donated T2 constructor should still be able to capture an empty
        // vent; do not require funding the advanced upgrade before any geo.
        const string prefix=UnitHelpers::GetSideForUnitName(worker.circuitDef.GetName())=="armada" ? "arm"
            : UnitHelpers::GetSideForUnitName(worker.circuitDef.GetName())=="cortex" ? "cor" : "leg";
        for (int tier=0;tier<2;++tier) {
            CCircuitDef@ definition=ai.GetCircuitDef(prefix+(tier==0 ? "geo" : "ageo"));
            if (definition is null || !worker.circuitDef.CanBuild(definition)
                || !GeothermalMath::Affordable(definition.costM,definition.costE,
                    aiEconomyMgr.metal.current,aiEconomyMgr.energy.current,
                    Economy::GetMinMetalIncomeLast10s(),income,
                    Global::RoleSettings::Front::GeothermalBudgetSeconds,
                    Global::RoleSettings::Front::GeothermalIncomeFraction)) continue;
            // Respect map/profile caps; this role does not open forbidden defs.
            if (!definition.IsAvailable(ai.frame)) continue;
            IUnitTask@ task=aiEconomyMgr.EnqueueLocalGeo(worker,definition,Global::Map::StartPos,
                Global::RoleSettings::Front::GeothermalRadius);
            if (task !is null) {
                @project=cast<IBuilderTask>(task);
                const AIFloat3 site=cast<IBuilderTask>(task).GetBuildPos();
                GenericHelpers::LogUtil("[FRONT][Geo] ordered "+definition.GetName()+" worker="+worker.id
                    +" site="+int(site.x)+","+int(site.z),1);
                return task;
            }
        }
        return null;
    }
}
