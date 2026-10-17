#include "air_build.as"
#include "../../systems/air/air_defence.as"
#include "../../systems/air/air_growth.as"

// Ordered, total dispatcher. Each action rechecks mutable claims before enqueue.
namespace AirRules {
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        AirEconomy::Tick();
        IBuilderTask@ current = cast<IBuilderTask>(u.task);
        if (current !is null && current.GetBuildType() < int(Task::BuildType::REPAIR)) return u.task;
        IUnitTask@ retirement = AirBuild::RetireStarter(u);
        if (retirement !is null) return AirBuild::Record(retirement, "starter.reclaim", u);
        if (MetalEconomy::Active()) return AirBuild::Record(MetalEconomy::AirTask(u), "metal.economy", u);
        const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        const bool commander = UnitHelpers::IsCommander(u.circuitDef);
        if (commander) {
            CCircuitUnit@ plant = AirBuild::NearestPlant(u);
            if (plant !is null) return AirBuild::Commander(u, plant);
        }
        IUnitTask@ t = null;
        if (AirEconomy::recovery) {
            @t = AirBuild::Resume(u, true);
            if (t !is null) return AirBuild::Record(t, "recovery.resume", u);
            @t = AirBuild::Energy(u, true);
            if (t !is null) return AirBuild::Record(t, "recovery.energy", u);
            @t = AirBuild::Assist(u, true);
            if (t !is null) return AirBuild::Record(t, "recovery.assist", u);
        }
        @t = AirBuild::Resume(u);
        if (t !is null) return AirBuild::Record(t, "project.resume", u);
        // Home spots precede the starter. Recovery never repeats a paid opening.
        if (AirEconomy::t1 + AirEconomy::t2 == 0 && aiTerrainMgr.GetLayoutInt("air.starter.retired",0) == 0) {
            // maxSpots limits native search candidates, not owned extractors.
            // Without an ownership check the commander keeps taking fourth,
            // fifth, ... spots and may never reach its nearby starter lab.
            if (AirEconomy::MexCount() < 3) {
                @t = aiEconomyMgr.EnqueueMexWithin(u, Global::Map::StartPos, 700.0f, 3, true);
                if (t !is null) return AirBuild::Record(t, "opening.mex", u);
            }
            if (AirEconomy::energy < 80.0f) {
                @t = AirBuild::Energy(u, false);
                if (t !is null) return AirBuild::Record(t, "opening.energy", u);
            }
        }
        @t = AirBuild::Factory(u, false);
        if (t !is null) return AirBuild::Record(t, Team::Ferry::requestPending ? "transport.plant" : "opening.plant", u);
        if (!AirEconomy::recovery && AirEconomy::OpeningSupportNeeded()) {
            @t = AirBuild::Nano(u, true);
            if (t !is null) return AirBuild::Record(t, "opening.support", u);
            @t = AirBuild::Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side)));
            if (t !is null) return AirBuild::Record(t, "opening.support.assist", u);
        }
        // T2 builders, including gifts, upgrade mexes without requiring a T2 plant.
        if ((!AirEconomy::TechGrowth() || AirEconomy::MassBombers() || AirEconomy::t2 == 0)
            && AirEconomy::BankedLab(ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side)))) {
            @t = AirBuild::Factory(u, true);
            if (t !is null) return AirBuild::Record(t, "production.banked", u);
        }
        @t = AirBuild::UpgradeMex(u);
        if (t !is null) return AirBuild::Record(t, "mex.upgrade", u);
        @t = AirBuild::AssistMex(u);
        if (t !is null) return AirBuild::Record(t, "mex.assist", u);
        CCircuitDef@ nextLab=ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        CCircuitDef@ transitionStore=ai.GetCircuitDef(UnitHelpers::GetMetalStorageNameForSide(side));
        if (nextLab !is null && AirMath::TransitionStorage(AirEconomy::t2>0,
            AirEconomy::bankM,aiEconomyMgr.metal.storage,nextLab.costM)
            && !AirBuild::FirstLabFunded(u, nextLab)
            && !AirBuild::Busy(transitionStore,Task::BuildType::STORE)) {
            @t=AirBuild::Utility(u,UnitHelpers::GetMetalStorageNameForSide(side),Task::BuildType::STORE,4);
            if (t !is null) return AirBuild::Record(t,"transition.storage",u);
        }
        @t = AirReclaim::MakeTask(u);
        if (t !is null) return AirBuild::Record(t, "energy.reclaim", u);
        // First access precedes discretionary shared economy/its assists.
        // Later factories retain the twenty-turret gate and capacity policy.
        if (AirEconomy::t2 == 0) {
            @t = AirBuild::Factory(u, true);
            if (t !is null) return AirBuild::Record(t, "transition.bay", u);
            if (AirEconomy::SavingForFirstLab()) {
                @t = AirBuild::TransitionMex(u);
                if (t !is null) return AirBuild::Record(t, "transition.mex", u);
                @t = AirBuild::Nano(u);
                if (t !is null) return AirBuild::Record(t, "transition.support", u);
                @t = AirBuild::Assist(u);
                if (t !is null) return AirBuild::Record(t, "transition.finish", u);
                return AirBuild::Record(aiBuilderMgr.Enqueue(TaskB::Wait(3 * SECOND)), "transition.save", u);
            }
        }
        { // One funded support decision, before shared growth/assistance.
            @t = AirBuild::Nano(u);
            if (t !is null) return AirBuild::Record(t, "overflow.support", u);
            @t = AirBuild::Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)));
            if (t !is null) return AirBuild::Record(t, "overflow.support.assist", u);
        }
        @t = AirBuild::Convert(u);
        if (t !is null) return AirBuild::Record(t, "mex.phase.convert", u);
        @t = AirGrowth::MakeTask(u);
        if (t !is null) return t;
        @t = AirBuild::FirstFusion(u);
        if (t !is null) return AirBuild::Record(t, "fusion.first", u);
        @t = AirBuild::Assist(u, false, ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)));
        if (t !is null) return AirBuild::Record(t, "support.assist", u);
        @t = AirBuild::Nano(u);
        if (t !is null) return AirBuild::Record(t, "production.support", u);
        @t = AirDefence::MakeTask(u);
        if (t !is null) return AirBuild::Record(t, "defence.base", u);
        if (AirEconomy::PreparingFusion()) {
            if (!AirEconomy::HasAdvancedBuilder()) {
                @t = AirBuild::Factory(u, true);
                if (t !is null) return AirBuild::Record(t, "fusion.access", u);
            }
        }
        // Close the finite early expansion before buying T2 access. New owned
        // mexes (including gifts anywhere on the map) still block reactor starts.
        const bool expand = AirEconomy::HasReactor() || (!AirEconomy::PreparingFusion()
            && AirEconomy::MexCount() < Global::RoleSettings::Air::PreFusionMexLimit);
        if (expand && !commander && AirEconomy::metal < 80.0f && aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, Global::RoleSettings::Air::HomeMexRadius) < 1) {
            @t = aiEconomyMgr.EnqueueMexWithin(u, Global::Map::StartPos, Global::RoleSettings::Air::HomeMexRadius, 0, true);
            if (t !is null) return AirBuild::Record(t, "mex.expand", u);
        }
        // Affordable production support and the first wind buffer must not starve
        // behind an aspirational energy target that moves upward with mex income.
        if (AirEconomy::energy >= 250.0f) {
            @t = AirBuild::Utility(u, UnitHelpers::GetEnergyStorageNameForSide(side), Task::BuildType::STORE, 1);
            if (t !is null) return AirBuild::Record(t, "storage.buffer", u);
        }
        // Production demand is a floor, plus energy for the next stage of T1 growth.
        const float targetE = AiMax(160.0f, AiMax(AirEconomy::metal * 45.0f, AirEconomy::demandE * 1.3f));
        if (!AirEconomy::TechGrowth() && (AirEconomy::energy < targetE || AirEconomy::recovery)) {
            @t = AirBuild::Energy(u, AirEconomy::recovery);
            if (t !is null) return AirBuild::Record(t, "energy.grow", u);
            @t = AirBuild::Assist(u, true);
            if (t !is null) return AirBuild::Record(t, "energy.assist", u);
        }
        @t = AirBuild::Utility(u, UnitHelpers::GetStaticRadarNameForSide(side), Task::BuildType::RADAR, 1);
        if (t !is null) return AirBuild::Record(t, "intel.radar", u);
        if (AirEconomy::bankM > aiEconomyMgr.metal.storage * 0.85f && aiEconomyMgr.metal.storage < AirEconomy::metal * 60.0f) {
            @t = AirBuild::Utility(u, UnitHelpers::GetMetalStorageNameForSide(side), Task::BuildType::STORE, 4);
            if (t !is null) return AirBuild::Record(t, "storage.metal", u);
        }
        if (!AirEconomy::TechGrowth() || AirEconomy::MassBombers()) {
            @t = AirBuild::Factory(u, true);
            if (t !is null) return AirBuild::Record(t, "production.bay", u);
        }
        if (AirEconomy::energy > 250.0f && aiEconomyMgr.energy.storage < AirEconomy::energy * 10.0f) {
            @t = AirBuild::Utility(u, UnitHelpers::GetEnergyStorageNameForSide(side), Task::BuildType::STORE, AiMin(8, 1 + int(AirEconomy::energy / 2000.0f)));
            if (t !is null) return AirBuild::Record(t, "storage.energy", u);
        }
        if (AirEconomy::MexesReady() && !AirEconomy::recovery && AirEconomy::bankE > aiEconomyMgr.energy.storage * 0.85f && AirEconomy::bankM < aiEconomyMgr.metal.storage * 0.8f
            && AirEconomy::energy > AirEconomy::demandE * 1.25f + 150.0f) {
            CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
            if (!AirBuild::Can(u, d)) @d = ai.GetCircuitDef(UnitHelpers::GetEnergyConverterNameForSide(side));
            if (d !is null && !AirBuild::Busy(d, Task::BuildType::CONVERT)) {
                @t = AirLayout::Place(u, d, Task::BuildType::CONVERT, Task::Priority::LOW);
                if (t !is null) return AirBuild::Record(t, "surplus.convert", u);
            }
        }
        // AIR owns its local structures. Shared defense/sensor queues may point
        // to allied resource clusters and must not recruit these constructors.
        @t = AirBuild::Assist(u);
        if (t !is null) return AirBuild::Record(t, "project.assist", u);
        // All aircraft remain available for economy; a renewable guard
        // would absorb their mobile build power indefinitely at a completed lab.
        CCircuitUnit@ plant = Factory::primaryT1AirPlant;
        if (!AirBuild::EconomyAircraft(u) && AirBuild::PlantHasWork(plant)) {
            // Non-interruptible guards explicitly start the native timeout;
            // interruptible guards deactivate their timer while assigned.
            @t = GuardHelpers::AssignWorkerGuard(u, plant, Task::Priority::NORMAL, false, 5 * SECOND);
            if (t !is null) return AirBuild::Record(t, "production.assist", u);
        }
        return AirBuild::Record(aiBuilderMgr.Enqueue(TaskB::Wait(3 * SECOND)), "wait", u);
    }
}
