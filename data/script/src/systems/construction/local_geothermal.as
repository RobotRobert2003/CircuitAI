// Shared TECH/SUPPORT policy. Native admission owns vent validation and the
// BAR build-over upgrade. A no-local-vent result is cached without RNG draws.
#include "../../helpers/math/geothermal_math.as"
#include "../../helpers/construction/owned_economy_helpers.as"
namespace LocalGeothermal {
    bool inspected = false;
    bool nearby = false;
    int censusFrame = -1;
    uint censusRevision = 0;
    float completedOutput = 0.0f;
    bool Enabled() {
        return Global::RoleSettings::Tech::LocalGeothermalEnabled
            && (Global::AISettings::Role == AiRole::TECH || Global::AISettings::Role == AiRole::SUPPORT);
    }
    bool HasLocal() {
        if (!Enabled()) return false;
        if (inspected) return nearby;
        inspected = true;
        const float radius = Global::RoleSettings::Tech::LocalGeothermalRadius;
        CCircuitDef@ definition = ai.GetCircuitDef(Name(false));
        if (definition is null) return false;
        for (int index = 0; index < ai.GetGeoSpotCount(); ++index) {
            const AIFloat3 position = ai.GetGeoSpot(index);
            if (MapHelpers::SqDist(position, Global::Map::StartPos) <= radius * radius
                && !aiTerrainMgr.IsZoneAlly(position)
                && aiTerrainMgr.CanUpgradeTerrain(definition, position)) nearby = true;
        }
        return nearby;
    }
    string Name(bool advanced) {
        const string side = Global::AISettings::Side;
        const string prefix = side == "armada" ? "arm" : (side == "cortex" ? "cor" : "leg");
        return prefix + (advanced ? "ageo" : "geo");
    }
    float Output() {
        if (!HasLocal()) return 0.0f;
        const uint revision = ai.GetOwnedUnitRevision();
        if (censusFrame == ai.frame && censusRevision == revision) return completedOutput;
        censusFrame = ai.frame;
        censusRevision = revision;
        completedOutput = 0.0f;
        // Only queried by local-geo roles. One census per used frame, never
        // per factory or candidate. Re-read completion before crediting energy.
        array<Id>@ units = OwnedEconomy::Geothermal();
        const string basic = Name(false), advanced = Name(true);
        const float radius = Global::RoleSettings::Tech::LocalGeothermalRadius;
        for (uint index = 0; index < units.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(units[index]);
            if (unit is null || unit.GetBuildProgress() < 1.0f) continue;
            const string name = unit.circuitDef.GetName();
            if (name != basic && name != advanced) continue;
            if (MapHelpers::SqDist(unit.GetPos(ai.frame), Global::Map::StartPos) <= radius * radius)
                completedOutput += aiEconomyMgr.GetEnergyMake(unit.circuitDef);
        }
        return completedOutput;
    }
    IUnitTask@ Work(CCircuitUnit@ worker) {
        if (!HasLocal() || worker is null || !worker.circuitDef.IsMobile()) return null;
        IUnitTask@ pending = aiBuilderMgr.FindQueuedTask(worker, int(Task::BuildType::GEO));
        if (pending !is null) return pending;
        const bool advanced = UnitHelpers::GetConstructorTier(worker.circuitDef) >= 2;
        CCircuitDef@ definition = ai.GetCircuitDef(Name(advanced));
        if (definition is null || !worker.circuitDef.CanBuild(definition)) return null;
        const float horizon = Global::RoleSettings::Tech::LocalGeothermalBudgetSeconds;
        const float energyIncome = Economy::GetMinEnergyIncomeLast10s();
        // Half the conservative income is reserved for the existing economy.
        // No assumed refund, future geo output or remote build power is spent.
        if (energyIncome < Global::RoleSettings::Tech::LocalGeothermalBootstrapEnergy
            || !GeothermalMath::Affordable(definition.costM, definition.costE,
                aiEconomyMgr.metal.current, aiEconomyMgr.energy.current,
                Economy::GetMinMetalIncomeLast10s(), energyIncome, horizon,
                Global::RoleSettings::Tech::LocalGeothermalIncomeFraction))
            return null;
        if (definition.maxThisUnit < 1) definition.maxThisUnit = 1;
        IUnitTask@ task = aiEconomyMgr.EnqueueLocalGeo(worker, definition, Global::Map::StartPos,
            Global::RoleSettings::Tech::LocalGeothermalRadius);
        if (task !is null) GenericHelpers::LogUtil("[Geo] ordered " + definition.GetName(), 1);
        return task;
    }
}
