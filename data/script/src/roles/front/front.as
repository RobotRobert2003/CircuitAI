// role: FRONT
#include "../../types/role_config.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/construction/factory_helpers.as"
#include "../../helpers/construction/economy_helpers.as"
#include "../../helpers/construction/guard_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
// Dynamic factory production + shared helpers
#include "../../helpers/objectives/objective_helpers.as"
#include "../../helpers/roles/role_limit_helpers.as"
#include "../../global.as"
#include "../../types/terrain.as"
#include "../../systems/production/factory_production.as"
#include "../../systems/production/front_opener.as"
#include "../../systems/combat/land_siege.as"
#include "../../systems/construction/front_geothermal.as"
#include "../../systems/construction/front_reclaim.as"
#include "../../systems/construction/front_eco_ladder.as"
#include "../../systems/construction/commander_front.as"
// Builder state and helpers for enqueueing structures like nanos
#include "../../manager/builder.as"
#include "../../manager/economy.as"

namespace RoleFront {

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/

    void Front_Init() {
        FrontGeothermal::Reset();
        GenericHelpers::LogUtil("Front role initialization logic executed", 2);

        // Apply FRONT role settings
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Front::AllyRange);

        // FRONT-only: Set default fire state for all T1 combat units to 3 (fire at everything)
        // Note: 2 = fire at will, 3 = fire at everything
        array<string> t1Combat = UnitHelpers::GetAllT1CombatUnits();
        for (uint i = 0; i < t1Combat.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
            if (d is null) continue;
            // Best-effort: if engine exposes fire-state setter, apply it
            // TODO: If SetFireState is not available, consider moving this to behaviour config for this profile only.
            d.SetFireState(Global::RoleSettings::Front::DefaultT1CombatFireState);
        }

        // Default to bot thresholds in Front init
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapBots;
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdBots;
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerBots; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerBots; 
        g_frontVehicleThresholdsApplied = false;

        Front_ApplyStartLimits();

        // Initialize dynamic factory production system for FRONT role when enabled
        if (Global::RoleSettings::Front::UseDynamicFactoryProduction) {
            FactoryProduction::Initialize();
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production system initialized", 2);
        } else {
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production disabled; using legacy factory selection", 2);
        }

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::FRONT, "FRONT");
    }

    void Front_ApplyStartLimits() {
        dictionary startLimits; 

        startLimits.set("armrectr", Global::RoleSettings::Front::StartCapRezBots);
        startLimits.set("cornecro", Global::RoleSettings::Front::StartCapRezBots);

        startLimits.set("armap", Global::RoleSettings::Front::StartCapT1AircraftPlants);
        startLimits.set("corap", Global::RoleSettings::Front::StartCapT1AircraftPlants);
        startLimits.set("legap", Global::RoleSettings::Front::StartCapT1AircraftPlants);

        startLimits.set("armsilo", Global::RoleSettings::Front::StartCapNukeSilos);
        startLimits.set("corsilo", Global::RoleSettings::Front::StartCapNukeSilos);
        startLimits.set("legsilo", Global::RoleSettings::Front::StartCapNukeSilos);

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Front start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    // Compute the total metal "power" of all FRONT army units using the military manager's armyCost.
    // This is an approximate metal-equivalent value including both mobile and static forces so that
    // base fortifications contribute when comparing against enemy surface investment.
    float Front_GetArmyMetalCostEstimate()
    {
        // NOTE: aiMilitaryMgr.armyCost is used elsewhere (e.g. factory switch logic) as a
        // metal-equivalent measure of our army. We reuse that here so FRONT compares its
        // strength against cached enemy metal costs on a consistent scale.

        float armyCost = aiMilitaryMgr.armyCost;
        if (!(armyCost == armyCost) || armyCost < 0.f) {
            armyCost = 0.f;
        }
        return armyCost;
    }

    // Adjust FRONT military quotas based on comparison of our army metal cost vs cached enemy surface cost.
    void Front_UpdateDynamicMilitaryQuotas()
    {
        // Estimate our army metal cost
        float ourArmyCost = Front_GetArmyMetalCostEstimate();

        // Enemy surface metrics (cost per player) are cached centrally in Military when
        // the enemy cost cache is updated; we just read the derived values here.
        float enemySurfaceCostPerPlayer = Military::GetEnemySurfaceCostPerPlayer();
        float enemySurfaceCostTotal     = Military::g_cachedTotalSurfaceCost; // for logging only

        // Defensive sanity checks
        if (!(enemySurfaceCostPerPlayer == enemySurfaceCostPerPlayer) || enemySurfaceCostPerPlayer < 0.f) {
            enemySurfaceCostPerPlayer = 0.f;
        }

        float attackThreshold = enemySurfaceCostPerPlayer * Global::RoleSettings::Front::DynamicQuotaEnemyCostAttackThresholdMultiplier;
        float withdrawThreshold = enemySurfaceCostPerPlayer * Global::RoleSettings::Front::DynamicQuotaEnemyCostWithdrawThresholdMultiplier;

        // Hysteresis logic:
        // - If currently underpowered (defensive), we only switch to aggressive if we exceed the ATTACK threshold.
        // - If currently aggressive (attacking), we only switch to underpowered if we drop below the WITHDRAW threshold.
        if (g_frontIsUnderpowered) {
            if (ourArmyCost >= attackThreshold) {
                g_frontIsUnderpowered = false;
            }
        } else {
            if (ourArmyCost < withdrawThreshold) {
                g_frontIsUnderpowered = true;
            }
        }

        // When underpowered vs enemy surface cost, push quotas high to encourage more army production.
        if (g_frontIsUnderpowered) {
            // Use a high cap and low attack threshold to trigger more frequent waves.
            //aiMilitaryMgr.quota.scout = 10;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::UnderpoweredAttackQuota;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::UnderpoweredRaidMinQuota;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::UnderpoweredRaidAvgQuota;

            GenericHelpers::LogUtil(
                "[FRONT][Quota] Underpowered vs enemy surface (ourArmyCost=" + ourArmyCost +
                " enemySurfaceCostTotal=" + enemySurfaceCostTotal +
                " enemySurfacePerPlayer=" + enemySurfaceCostPerPlayer +
                " attackThr=" + attackThreshold +
                " withdrawThr=" + withdrawThreshold +
                ") => HIGH quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                3
            );
        } else {
            // When not underpowered, keep quotas near their front-role defaults (bots/vehicles split).
            int baseScout = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryScoutCapVehicles
                : Global::RoleSettings::Front::MilitaryScoutCapBots;
            float baseAttack = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryAttackThresholdVehicles
                : Global::RoleSettings::Front::MilitaryAttackThresholdBots;
            float baseRaidMin = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles
                : Global::RoleSettings::Front::MilitaryRaidMinPowerBots;
            float baseRaidAvg = g_frontVehicleThresholdsApplied
                ? Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles
                : Global::RoleSettings::Front::MilitaryRaidAvgPowerBots;

            aiMilitaryMgr.quota.scout = baseScout;
            aiMilitaryMgr.quota.attack = baseAttack;
            aiMilitaryMgr.quota.raid.min = baseRaidMin;
            aiMilitaryMgr.quota.raid.avg = baseRaidAvg;

            GenericHelpers::LogUtil(
                "[FRONT][Quota] Competitive vs enemy surface (ourArmyCost=" + ourArmyCost +
                " enemySurfaceCostTotal=" + enemySurfaceCostTotal +
                " enemySurfacePerPlayer=" + enemySurfaceCostPerPlayer +
                " attackThr=" + attackThreshold +
                " withdrawThr=" + withdrawThreshold +
                ") => BASE quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                4
            );
        }
    }

    // Delay for dynamic quota adjustments: 5 minutes in frames
    const int FRONT_DYNAMIC_QUOTA_DELAY_FRAMES = Global::RoleSettings::Front::DynamicQuotaDelaySeconds * SECOND;

    void Front_MainUpdate() {
        // Delay dynamic quota adjustments until 5 minutes into the game to avoid
        // early-game oscillations while armies and caches are still forming.
        if (ai.frame < FRONT_DYNAMIC_QUOTA_DELAY_FRAMES) {
            return;
        }

        // Dynamically adjust FRONT military quotas based on army vs enemy surface metal costs
        Front_UpdateDynamicMilitaryQuotas();
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Front_EconomyUpdate() {
        float metalIncome = Economy::GetMinMetalIncomeLast10s();
        float energyIncome = Economy::GetMinEnergyIncomeLast10s();
        Front_IncomeLimits(metalIncome, energyIncome);

        // One-time switch for T1 combat units to 'raider' role when metal income > 250
        if (!g_frontT1CombatRoleSwitchDone && metalIncome > 250.0f) {
            g_frontT1CombatRoleSwitchDone = true;
            int raiderType = aiRoleMasker.GetTypeMask("raider").type;
            if (raiderType >= 0) {
                array<string> t1Combat = UnitHelpers::GetAllT1CombatUnits();
                for (uint i = 0; i < t1Combat.length(); ++i) {
                    CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
                    if (d !is null) {
                        d.SetMainRole(raiderType);
                        GenericHelpers::LogUtil("[FRONT] Switched " + t1Combat[i] + " to raider role (income > 250)", 2);
                    }
                }
            }
        }
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    // Track if vehicle thresholds have been applied (to avoid reapplying repeatedly)
    bool g_frontVehicleThresholdsApplied = false;

    // Track if T1 combat units have been switched to raider role
    bool g_frontT1CombatRoleSwitchDone = false;

    // Track if we are currently in "underpowered" mode (hysteresis state)
    bool g_frontIsUnderpowered = true; 

    // One-time T1 raider opener state for the first suitable T1 land factory
    bool g_frontRaiderOpenerDone = false;

    // One-time scout rush state for the very first T1 land factory (bot or vehicle)
    bool g_frontScoutRushFinished = false;
    int g_frontScoutRushFactoryId = -1;

    // Attempt to enqueue a scout for the one-time scout rush from the first T1 land factory.
    // Returns a task if a scout was enqueued, otherwise null.
    IUnitTask@ Front_TryScoutRush(CCircuitUnit@ u, const string &in factoryName, const string &in side)
    {
        if (u is null) return null;
        if (g_frontScoutRushFinished || FrontOpener::WasQueued("scout")) return null;
        if (!UnitHelpers::IsT1BotLab(factoryName) && !UnitHelpers::IsT1VehicleLab(factoryName)) return null;

        // Lock to the first T1 land factory encountered
        if (g_frontScoutRushFactoryId == -1) {
            g_frontScoutRushFactoryId = u.id;
            GenericHelpers::LogUtil("[FRONT] ScoutRush locked to factory id=" + g_frontScoutRushFactoryId + " (" + factoryName + ")", 2);
        }
        if (u.id != g_frontScoutRushFactoryId) return null; // only the locked factory performs the rush

        int target = Global::RoleSettings::Front::ScoutRushCount;
        if (target <= 0) { g_frontScoutRushFinished = true; return null; }

        string scoutName = UnitHelpers::GetFrontT1ScoutForFactory(factoryName, side);
        if (scoutName == "") { g_frontScoutRushFinished = true; return null; }

        CCircuitDef@ sdef = ai.GetCircuitDef(scoutName);
        if (sdef is null || !sdef.IsAvailable(ai.frame)) {
            // If unavailable, complete rush to avoid perpetual attempts
            g_frontScoutRushFinished = true;
            return null;
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        for (int i = 0; i < target; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, sdef, pos, 64.f)
            );
        }
        g_frontScoutRushFinished = true;
        FrontOpener::MarkQueued("scout");
        GenericHelpers::LogUtil("[FRONT] ScoutRush enqueued count=" + target, 2);
        return last;
    }

    // One-time T1 raider-style opener: enqueue a batch of cheap land raider units
    // from the first suitable T1 land factory after constructor enforcement.
    IUnitTask@ Front_TryT1RaiderOpener(CCircuitUnit@ u, const string &in factoryName, const string &in side)
    {
        if (u is null) return null;
        if (g_frontRaiderOpenerDone || FrontOpener::WasQueued("batch")) return null;
        if (!UnitHelpers::IsT1BotLab(factoryName) && !UnitHelpers::IsT1VehicleLab(factoryName)) return null;

        string raiderName = UnitHelpers::GetFrontT1RaiderForFactory(factoryName, side);
        if (raiderName == "") {
            g_frontRaiderOpenerDone = true;
            return null;
        }

        CCircuitDef@ pdef = ai.GetCircuitDef(raiderName);
        CCircuitDef@ tank = FrontOpener::ChooseTank(u, factoryName, side);
        if (tank !is null) { @pdef = tank; raiderName = tank.GetName(); }
        if (pdef is null || !pdef.IsAvailable(ai.frame)) {
            g_frontRaiderOpenerDone = true;
            return null;
        }
        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        const int count = Global::RoleSettings::Front::RaiderOpenerCount;
        if (tank !is null && count > 0) FrontOpener::Begin(u, tank, count);
        for (int i = 0; i < count; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, pdef, pos, 64.f)
            );
            if (tank !is null) FrontOpener::Recruit(last);
        }
        g_frontRaiderOpenerDone = true;
        FrontOpener::MarkQueued("batch");
        GenericHelpers::LogUtil("[FRONT] T1 raider opener enqueued count=" + count + " unit=" + raiderName, 2);
        return last;
    }

    // Ensure labs recruit a minimum number of constructors
    // - T1 Bot Lab: at least MinT1BotConstructorCount T1 bot constructors (ck)
    // - T1 Vehicle Plant: at least MinT1VehicleConstructorCount T1 vehicle constructors (cv)
    // - T2 Bot Lab: maintain at least MinT2BotConstructorCount T2 bot constructors
    // - T2 Vehicle Plant: maintain at least MinT2VehicleConstructorCount T2 vehicle constructors
    IUnitTask@ Front_FactoryAiMakeTask(CCircuitUnit@ u)
    {
        if (u is null) return aiFactoryMgr.DefaultMakeTask(u);
        const CCircuitDef@ facDef = u.circuitDef;
        if (facDef is null) return aiFactoryMgr.DefaultMakeTask(u);

        string factoryName = facDef.GetName();
        string side = UnitHelpers::GetSideForUnitName(factoryName);

        // T1 Bot Lab enforcement
        if (UnitHelpers::IsT1BotLab(factoryName)) {
            array<string> botConstructorNames = UnitHelpers::GetT1BotConstructors(side);
            if (botConstructorNames.length() > 0) {
                string botConstructorName = botConstructorNames[0];
                int existingBotConstructors = UnitDefHelpers::GetUnitDefCount(botConstructorName);
                if (existingBotConstructors < Global::RoleSettings::Front::MinT1BotConstructorCount) {
                    CCircuitDef@ ctorDef = ai.GetCircuitDef(botConstructorName);
                    if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 bot lab
            IUnitTask@ rushTask = Front_TryScoutRush(u, factoryName, side);
            if (rushTask !is null) return rushTask;

            // After scout rush, try one-time T1 raider opener for T1 bot lab
            IUnitTask@ raiderTask = Front_TryT1RaiderOpener(u, factoryName, side);
            if (raiderTask !is null) return raiderTask;
        }

        // T1 Vehicle Plant enforcement
        if (UnitHelpers::IsT1VehicleLab(factoryName)) {
            array<string> vehicleConstructorNames = UnitHelpers::GetT1VehicleConstructors(side);
            if (vehicleConstructorNames.length() > 0) {
                string vehicleConstructorName = vehicleConstructorNames[0];
                int existingVehicleConstructors = UnitDefHelpers::GetUnitDefCount(vehicleConstructorName);
                if (existingVehicleConstructors < Global::RoleSettings::Front::MinT1VehicleConstructorCount) {
                    CCircuitDef@ vdef = ai.GetCircuitDef(vehicleConstructorName);
                    if (vdef !is null && vdef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos2 = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, vdef, pos2, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 vehicle plant
            IUnitTask@ rushTask2 = Front_TryScoutRush(u, factoryName, side);
            if (rushTask2 !is null) return rushTask2;

            // After scout rush, try one-time T1 raider opener for T1 vehicle plant
            IUnitTask@ raiderTask2 = Front_TryT1RaiderOpener(u, factoryName, side);
            if (raiderTask2 !is null) return raiderTask2;
        }

        // T2 Bot Lab enforcement (Front-specific minimum T2 bot constructors)
        if (UnitHelpers::IsT2BotLab(factoryName)) {
            int t2CtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            if (t2CtorCount < Global::RoleSettings::Front::MinT2BotConstructorCount) {
                array<string> t2BotCtors = UnitHelpers::GetT2BotConstructors(side);
                if (t2BotCtors.length() > 0) {
                    CCircuitDef@ t2Ctor = ai.GetCircuitDef(t2BotCtors[0]);
                    if (t2Ctor !is null && t2Ctor.IsAvailable(ai.frame)) {
                        const AIFloat3 pos3 = u.GetPos(ai.frame);
                        GenericHelpers::LogUtil("[FRONT][Factory] T2 bot ctor below target (" + t2CtorCount + "), enqueue '" + t2BotCtors[0] + "'", 3);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2Ctor, pos3, 64.f)
                        );
                    }
                }
            }
        }

        // T2 Vehicle Plant enforcement (Front-specific minimum T2 vehicle constructors)
        if (UnitHelpers::IsT2VehicleLab(factoryName) && Global::RoleSettings::Front::MinT2VehicleConstructorCount > 0) {
            int t2VehCtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleConstructors());
            if (t2VehCtorCount < Global::RoleSettings::Front::MinT2VehicleConstructorCount) {
                array<string> t2VehCtors = UnitHelpers::GetT2VehicleConstructors(side);
                if (t2VehCtors.length() > 0) {
                    CCircuitDef@ t2Veh = ai.GetCircuitDef(t2VehCtors[0]);
                    if (t2Veh !is null && t2Veh.IsAvailable(ai.frame)) {
                        const AIFloat3 pos4 = u.GetPos(ai.frame);
                        GenericHelpers::LogUtil("[FRONT][Factory] T2 vehicle ctor below target (" + t2VehCtorCount + "), enqueue '" + t2VehCtors[0] + "'", 3);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2Veh, pos4, 64.f)
                        );
                    }
                }
            }
        }

        IUnitTask@ siege = LandSiege::Produce(u);
        if (siege !is null) return siege;

        // After constructor guarantees (T1/T2) and optional scout rushes, prefer dynamic factory
        // production for all factories (T1/T2 labs, air, gantries, etc.) when enabled.
        if (Global::RoleSettings::Front::UseDynamicFactoryProduction) {
            IUnitTask@ dynTask = FactoryProduction::MakeTask(u);
            if (dynTask !is null) {
                return dynTask;
            }
            GenericHelpers::LogUtil("[FRONT] Dynamic factory production returned null for '" + factoryName + "', using default", 3);
        }

        // Fall back to default when no rule triggers
        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Front_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if(isStart) {
            if(Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Front_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
        }
   
        return "";
    }

    // Factory unit lifecycle hooks (Front role)
    void Front_FactoryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) {
            GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded: unit=<null>", 2);
            return;
        }

        if (usage != Unit::UseAs::FACTORY)
		return;

        const CCircuitDef@ facDef = unit.circuitDef;
        string factoryName = (facDef is null ? "" : facDef.GetName());

        // If we build a vehicle lab at any point, switch to vehicle thresholds
        if (!g_frontVehicleThresholdsApplied && factoryName != "" && UnitHelpers::IsT1VehicleLab(factoryName)) {
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapVehicles;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdVehicles;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles;
            g_frontVehicleThresholdsApplied = true;
            GenericHelpers::LogUtil("[FRONT] Vehicle lab built; applied vehicle raid/attack thresholds", 2);
        }
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) {
            array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
            for (uint i = 0; i < spam.length(); ++i)
                ai.GetCircuitDef(spam[i]).SetIgnore(true);
        }

        GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage, 3);
        // Note: Factory registration and preferred anchors are centralized in Factory manager.
        // Front role currently has no additional per-factory behavior here.
    }

    void Front_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        //GenericHelpers::LogUtil("[FRONT] FactoryAiUnitRemoved id=" + (unit is null ? -1 : unit.id) + " usage=" + usage, 3);
        FrontOpener::FactoryRemoved(unit);
    }

    bool Front_AiIsSwitchTime(int lastSwitchFrame) {
        int interval = (30 * SECOND);
        return (lastSwitchFrame + interval) <= ai.frame;
    }

    bool Front_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        const bool isOK = (armyCost > Global::RoleSettings::Front::SwitchFactoryCostMultiplier * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        assistRequired = !isOK;
        return isOK;
    }

    int Front_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Front::MinAiSwitchTime, Global::RoleSettings::Front::MaxAiSwitchTime) * SECOND;
    }

    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    
    IUnitTask@ Front_MilitaryAiMakeTask(CCircuitUnit@ unit) {
        IUnitTask@ task = FrontOpener::MilitaryTask(unit);
        return task is null ? aiMilitaryMgr.DefaultMakeTask(unit) : task;
    }

    // Counter for scout assignment
    int g_frontScoutAssignmentCount = 0;

    void Front_MilitaryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage) {
        if (unit is null) return;
        FrontOpener::Admit(unit);
        
        // Only apply to the first N units
        if (g_frontScoutAssignmentCount >= Global::RoleSettings::Front::ScoutAssignmentLimit) return;

        string name = unit.circuitDef.GetName();
        if (name == "armpw" || name == "corak" || name == "leggob") {
            // Assign SCOUT attribute (workaround as AddRole is not available on instances)
            // We use the attribute masker to get/create a "scout" attribute ID.
            unit.AddAttribute(aiAttrMasker.GetTypeMask("scout").type);
            g_frontScoutAssignmentCount++;
            GenericHelpers::LogUtil("[FRONT] Assigned SCOUT attribute to " + name + " (" + g_frontScoutAssignmentCount + "/" + Global::RoleSettings::Front::ScoutAssignmentLimit + ")", 2);
        }
    }

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    IUnitTask@ Front_BuilderAiMakeTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Front_BuilderAiMakeTask] called for builder", 3);
        if (builder is null) return null; // Defensive check

        if(UnitHelpers::IsCommander(builder.circuitDef)) {
            IUnitTask@ frontWork=CommanderFront::Work(builder);
            if(frontWork !is null) return frontWork;
        }

        // Select explicit geo work before asking native to enqueue another
        // energy task. Overriding an already-created task would leak work.
        IUnitTask@ geothermal=FrontGeothermal::Work(builder);
        if (geothermal !is null) return geothermal;
        // Owner (2026-10-16): after a fusion, winds and solars come down, those round the factories first
        IUnitTask@ reclaim=FrontReclaim::Work(builder);
        if (reclaim !is null) return reclaim;
        // Owner (2026-10-16): fusion, second fusion, advanced fusion, second advanced fusion, gantry
        IUnitTask@ ladderGantry=Front_TryLadderGantry(builder);
        if (ladderGantry !is null) return ladderGantry;
        IUnitTask@ ladder=FrontEcoLadder::Work(builder);
        if (ladder !is null) return ladder;
        // Pre-create and cache a single default task instance; never recreate.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "FRONT");

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return defaultTask;

        // Early return: if the default task represents a resource expansion (MEX/GEO variants), keep it.
        IBuilderTask@ defaultBuilderTask = cast<IBuilderTask>(defaultTask);
        if (defaultBuilderTask !is null) {
            Task::BuildType dbt = Task::BuildType(defaultBuilderTask.GetBuildType());
            if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
                dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP ||
                dbt == Task::BuildType::ENERGY) {
                GenericHelpers::LogUtil("[FRONT] defaultTask is MEX/MEXUP/GEO/GEOUP/ENERGY; returning early", 3);
                return defaultTask;
            }

            // If the default task is a radar but we're low on stored energy (<90% of storage)
            // and recent energy income is also low (<200 over last 10 seconds), prefer building
            // a solar collector instead to stabilize the grid.
            if (dbt == Task::BuildType::RADAR) {
                float energyCurrent = aiEconomyMgr.energy.current;
                float energyStorage = aiEconomyMgr.energy.storage;
                float energyIncomeMin10s = Economy::GetMinEnergyIncomeLast10s();
                if (energyStorage > 0.0f
                    && energyCurrent < energyStorage * 0.9f
                    && energyIncomeMin10s < 200.0f) {
                    string unitSide = Global::AISettings::Side;
                    IUnitTask@ solarTask = Builder::EnqueueT1Solar(
                        builder.id,
                        unitSide,
                        builder.GetPos(ai.frame),
                        /*shake*/ SQUARE_SIZE * 16,
                        /*timeout*/ 60 * SECOND
                    );
                    if (solarTask !is null) {
                        GenericHelpers::LogUtil("[FRONT] Overriding RADAR defaultTask with T1 solar (energy < 90% storage and income < 200)", 3);
                        return solarTask;
                    }
                }
            }
        }

        // Commander-specific logic: delegate to commander builder logic when applicable.
        bool isCommander = UnitHelpers::IsCommander(udef);
        if (isCommander) {
            return Front_Commander_AiMakeTask(builder, defaultTask);
        }

        // Route T1 land constructors (bot or vehicle) to FRONT logic; others fallback
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            if (builder is Builder::primaryT1BotConstructor || builder is Builder::secondaryT1BotConstructor
             || builder is Builder::primaryT1VehConstructor || builder is Builder::secondaryT1VehConstructor) {
                // Use same economy snapshot style as T2: min over last 10s for incomes
                bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
                float metalIncome = Economy::GetMinMetalIncomeLast10s();
                float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
            }
        } else if (ctorTier == 2) {
            // Mirror TECH role routing: handle primary/secondary T2 bot constructors explicitly
            bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            float metalIncome = Economy::GetMinMetalIncomeLast10s();
            float energyIncome = Economy::GetMinEnergyIncomeLast10s();
            float metalCurrent = aiEconomyMgr.metal.current;
            bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Front::EnergyStorageLowPercent;
            if (builder is Builder::primaryT2BotConstructor || builder is Builder::secondaryT2BotConstructor || builder is Builder::freelanceT2BotConstructor) {
                return Front_T2Constructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
            }
        }
        // Fallback to cached default task
        return defaultTask;
    }

    /******************************************************************************

    BUILDER LOGIC (COMMANDER)

    ******************************************************************************/ 

    // For the first 2 minutes of the game, keep the commander assigned to guard
    // the primary T1 bot lab or primary T1 vehicle plant (if present).
    IUnitTask@ Front_Commander_AiMakeTask(CCircuitUnit@ comm, IUnitTask@ defaultTask)
    {
        if (comm is null) return defaultTask;

        // 2 minutes in frames: 2 * 60 * SECOND
        const int FRONT_COMMANDER_GUARD_DEADLINE = 2 * 60 * SECOND;
        if (ai.frame > FRONT_COMMANDER_GUARD_DEADLINE) {
            // After the early window, fall back to default behavior
            return defaultTask;
        }

        // Prefer guarding the primary T1 bot lab; otherwise guard the primary T1 vehicle plant.
        CCircuitUnit@ target = null;
        if (Factory::primaryT1BotLab !is null) {
            @target = Factory::primaryT1BotLab;
        } else if (Factory::primaryT1VehPlant !is null) {
            @target = Factory::primaryT1VehPlant;
        }

        if (target is null) {
            // No suitable factory yet; let normal builder/commander logic handle this frame
            return defaultTask;
        }

        // Assign a high-priority guard task so the commander sticks near the frontline factory
        IUnitTask@ guardTask = GuardHelpers::AssignWorkerGuard(
            comm,
            target,
            Task::Priority::HIGH,
            true,
            10 * SECOND // guard duration; can be renewed while within deadline
        );

        return (guardTask !is null ? guardTask : defaultTask);
    }

    CCircuitUnit@ energizer1 = null;
	CCircuitUnit@ energizer2 = null;

    void Front_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		//LogUtil("BUILDER::AiUnitAdded:" + unit.circuitDef, 2);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

		// constructor with BASE attribute is assigned to tasks near base
		if (cdef.costM < Global::RoleSettings::Front::BuilderCostThresholdForBase) {
			if (energizer1 is null
				&& (uint(cdef.count) > aiMilitaryMgr.GetGuardTaskNum() || cdef.IsAbleToFly()))
			{
				@energizer1 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		} else {
			if (energizer2 is null) {
				@energizer2 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		}

	}

    void Front_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (energizer1 is unit)
			@energizer1 = null;
		else if (energizer2 is unit)
			@energizer2 = null;
	}

    void Front_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Front_BuilderAiTaskAdded] called for task", 3);
    }

    void Front_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {

    }

    /******************************************************************************

    ECONOMY LOGIC

    ******************************************************************************/ 

    void Front_IncomeLimits(float metalIncome, float energyIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int cap = int(metalIncome / Global::RoleSettings::Front::MetalIncomePerLab);

        // Scale Tier 2 bot/vehicle lab caps by economy: 35 metal income per lab
        Front_IncomeLabLimits(metalIncome);
        Front_IncomeBuilderLimits(metalIncome);
        Front_IncomeNanoLimits(energyIncome);
        FrontEcoLadder::ApplyCaps();   // Front::EcoLadder: the native eco follows the ladder's stage

        //Always apply map limits, regardless of how eco changes labs limits
        dictionary mapLimits = Global::Map::Config.UnitLimits;
        UnitHelpers::ApplyUnitLimits(mapLimits);
    }

    void Front_IncomeLabLimits(float metalIncome) {
        // Apply hard caps for T2 labs from global settings
        int maxT2Bot = Global::RoleSettings::Front::MaxT2BotLabs;
        int maxT2Veh = Global::RoleSettings::Front::MaxT2VehicleLabs;

        string side = Global::AISettings::Side;
        
        // T2 Bot Labs
        array<string> t2BotLabs = UnitHelpers::GetT2BotLabs(side);
        UnitHelpers::BatchApplyUnitCaps(t2BotLabs, maxT2Bot);

        // T2 Vehicle Labs
        array<string> t2VehLabs = UnitHelpers::GetT2VehicleLabs(side);
        UnitHelpers::BatchApplyUnitCaps(t2VehLabs, maxT2Veh);

        // Gantries
        array<string> gantries = UnitHelpers::GetAllGantries();
        // Front::EcoLadder: no native gantry; the ladder raises the allowance. Played (h25):
        // native gantries at stage 3, and a native order that never framed blocking the ladder's
        int gantryCap = (!FrontEcoLadder::On() && metalIncome >= Global::RoleSettings::Front::MetalIncomeForGantry) ? 1 : 0;
        if (g_frontGantryAllowance > gantryCap) gantryCap = g_frontGantryAllowance;   // never below what the ladder raised
        UnitHelpers::BatchApplyUnitCaps(gantries, gantryCap);
    }

    /******************************************************************************

    ECO LADDER GANTRY (Global::RoleSettings::Front::EcoLadder*)

    ******************************************************************************/

    int g_frontGantryAllowance = 0;
    // Our T2 factories and gantries that stand finished, with their turret counts
    void Front_SpendFactories(array<CCircuitUnit@>@ found, array<int>@ nanos) {
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            const string n = f.circuitDef.GetName();
            if (!UnitHelpers::IsT2BotLab(n) && !UnitHelpers::IsT2VehicleLab(n) && !UnitHelpers::IsLandGantry(n)) continue;
            found.insertLast(f); nanos.insertLast(Factory::_GetNanoCount(f));
        }
    }

    // A site the engine accepts for a gantry: around each finished T2 factory of ours, then at
    // 600/1200/1800 from the start toward the map centre, spiralling out 96 a ring.
    // (played: the native EnqueueLandGantry tried only near the preferred factory spot: "no site at all")
    bool Front_GantrySite(CCircuitDef@ gantry, AIFloat3 &out site) {
        array<AIFloat3> anchors;
        array<CCircuitUnit@> facs; array<int> nanos;
        Front_SpendFactories(facs, nanos);
        for (uint i = 0; i < facs.length(); ++i) anchors.insertLast(facs[i].GetPos(ai.frame));
        const AIFloat3 start = Global::Map::StartPos;
        const AIFloat3 centre(float(aiTerrainMgr.GetTerrainWidth()) * 0.5f, 0.0f, float(aiTerrainMgr.GetTerrainHeight()) * 0.5f);
        const float d = sqrt(MapHelpers::SqDist(start, centre));
        for (int k = 1; k <= 3 && d > 1.0f; ++k) {
            const float f = AiMin(float(k) * 600.0f, d) / d;
            anchors.insertLast(AIFloat3(start.x + (centre.x - start.x) * f, 0.0f, start.z + (centre.z - start.z) * f));
        }
        const int facing = LayoutHelpers::FacingToward(start, centre);
        for (uint a = 0; a < anchors.length(); ++a) {
            for (int ring = 1; ring <= 8; ++ring) {
                for (int k = 0; k < 8; ++k) {
                    const float ang = 0.7854f * float(k);
                    AIFloat3 p(anchors[a].x + cos(ang) * 96.0f * float(ring), 0.0f, anchors[a].z + sin(ang) * 96.0f * float(ring));
                    if (p.x < 200.0f || p.z < 200.0f || p.x > float(aiTerrainMgr.GetTerrainWidth()) - 200.0f || p.z > float(aiTerrainMgr.GetTerrainHeight()) - 200.0f) continue;
                    if (!aiTerrainMgr.CanReserveBuilding(gantry, p, facing)) continue;
                    site = p;
                    return true;
                }
            }
        }
        return false;
    }

    // Owner (2026-10-16): the eco ladder's last step (FrontEcoLadder::S_GANTRY, two advanced fusions
    // standing): one land gantry, held until metal income reaches Front::EcoLadderGantryMetalIncome
    // (150). Sited round our T2 factories, then round the eco anchor and the
    // start, then engine-sited round the eco anchor. Played (h25, All That Glitters +75): "no gantry
    // site", then a native gantry order that never framed held it silently for 10 minutes; every hold
    // is logged now, and another order without a frame is waited on for 90 s only.
    IUnitTask@ g_frontLadderGantryTask = null;
    int g_frontLadderGantryRetry = -1;
    int g_frontLadderGantryLog = -100000;
    int g_frontStaleGantrySince = -1;   // first frame Builder counted a land gantry order with no frame of it
    int g_frontLadderGantryTry = 0;     // engine-sited orders so far; each retry takes the next anchor
    AIFloat3 g_frontLadderGantrySite;   // where the open order was placed
    array<AIFloat3> g_frontFailedGantrySites;   // orders that died there with no frame
    // Played (h27, Scylla +75, corner start): five engine-sited orders round the corner died, and the next
    // one went back to the same spots; a spot within 500 of a dead order is skipped now
    bool Front_GantrySiteFailed(const AIFloat3 &in p) {
        for (uint i = 0; i < g_frontFailedGantrySites.length(); ++i)
            if (MapHelpers::SqDist(p, g_frontFailedGantrySites[i]) < 500.0f * 500.0f) return true;
        return false;
    }
    // Engine-sited anchors, one per retry: the start, then 600, 1200, 1800 and 2400 toward the centre, skipping
    // any near a dead order. Played (h26, All That Glitters +75): the eco anchor alone sat on the map edge and
    // every order died there within 7 s, four times; (h27, Scylla +75) the preferred factory spot in a corner
    // start died too, so it is no longer tried.
    // Owner (2026-10-17): FrontEcoLadder::GantryAnchors (behind and beside the start) instead of steps toward
    // the centre; played (p17c, All That Glitters +75) the steps toward the centre were on the front line.
    AIFloat3 Front_LadderGantryFallback(int k) {
        array<AIFloat3>@ a = FrontEcoLadder::GantryAnchors();
        const int n = int(a.length());
        for (int j = 0; j < n; ++j) {
            const AIFloat3 p = a[(k + j) % n];
            if (!Front_GantrySiteFailed(p)) return p;
        }
        return a[k % n];   // all dead: go round again
    }
    // Logged at most once a minute: why the ladder's gantry is not ordered (played h25: silent for 10 min)
    IUnitTask@ Front_LadderGantryHeld(const string &in why) {
        if (ai.frame - g_frontLadderGantryLog >= 60 * SECOND) {
            g_frontLadderGantryLog = ai.frame;
            GenericHelpers::LogUtil("[FRONT][Eco] gantry held: " + why, 1);
        }
        return null;
    }
    // A site for the ladder's gantry: rings of 128 out to 2048 round FrontEcoLadder::GantryAnchors (behind
    // and beside the start; owner, 2026-10-17: no longer round the T2 factories first, which stand forward).
    // Played (h25, All That Glitters): "no gantry site" near the T2 factories.
    bool Front_LadderGantrySite(CCircuitDef@ gantry, AIFloat3 &out site) {
        const AIFloat3 start = Global::Map::StartPos;
        const AIFloat3 centre(float(aiTerrainMgr.GetTerrainWidth()) * 0.5f, 0.0f, float(aiTerrainMgr.GetTerrainHeight()) * 0.5f);
        const int facing = LayoutHelpers::FacingToward(start, centre);
        array<AIFloat3>@ anchors = FrontEcoLadder::GantryAnchors();
        for (uint a = 0; a < anchors.length(); ++a) {
            for (int ring = 1; ring <= 16; ++ring) {
                for (int k = 0; k < 12; ++k) {
                    const float ang = 0.5236f * float(k);
                    AIFloat3 p(anchors[a].x + cos(ang) * 128.0f * float(ring), 0.0f, anchors[a].z + sin(ang) * 128.0f * float(ring));
                    if (p.x < 200.0f || p.z < 200.0f || p.x > float(aiTerrainMgr.GetTerrainWidth()) - 200.0f || p.z > float(aiTerrainMgr.GetTerrainHeight()) - 200.0f) continue;
                    if (Front_GantrySiteFailed(p) || !aiTerrainMgr.CanReserveBuilding(gantry, p, facing)) continue;
                    site = p;
                    return true;
                }
            }
        }
        return false;
    }
    IUnitTask@ Front_TryLadderGantry(CCircuitUnit@ u) {
        if (!FrontEcoLadder::On() || FrontEcoLadder::Stage() != FrontEcoLadder::S_GANTRY || !FrontEcoLadder::IsLadderT2(u)) return null;
        const string side = Global::AISettings::Side;
        CCircuitDef@ gantry = ai.GetCircuitDef(UnitHelpers::GetLandGantryForSide(side));
        if (gantry is null || !u.circuitDef.CanBuild(gantry)) return null;
        const int ours = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllGantries());   // standing and framed
        if (ours > 0) return null;
        if (g_frontLadderGantryTask !is null) {
            if (!g_frontLadderGantryTask.IsDead()) return null;
            // the order died with no frame: that spot is not tried again
            @g_frontLadderGantryTask = null;
            g_frontFailedGantrySites.insertLast(g_frontLadderGantrySite);
            // native gantries are off while the ladder is on, so a queued gantry with nothing framed is our dead
            // order. Played (h27, Scylla +75): the counter stayed up after the order died and the ladder then held
            // on "another gantry order is queued with no frame" for the rest of the game
            if (aiBuilderMgr.GetUnfinishedCount(gantry) == 0) { Builder::LandGantryQueuedCount = 0; g_frontStaleGantrySince = -1; }
            g_frontLadderGantryRetry = ai.frame + 30 * SECOND;
            GenericHelpers::LogUtil("[FRONT][Eco] gantry order died with no frame at " + int(g_frontLadderGantrySite.x) + "," + int(g_frontLadderGantrySite.z)
                + " (" + g_frontFailedGantrySites.length() + " dead spots); retry in 30 s at the next site", 1);
            return null;
        }
        // Another order (native or a stale counter) with no frame: wait 90 s for it, then order our own
        if ((Builder::LandGantryQueuedCount + Builder::WaterGantryQueuedCount) > 0) {
            if (g_frontStaleGantrySince < 0) g_frontStaleGantrySince = ai.frame;
            if (ai.frame - g_frontStaleGantrySince < 90 * SECOND)
                return Front_LadderGantryHeld("another gantry order is queued with no frame (" + ((ai.frame - g_frontStaleGantrySince) / SECOND) + " of 90 s)");
        } else g_frontStaleGantrySince = -1;
        if (ai.frame < g_frontLadderGantryRetry) return null;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        if (mi < Global::RoleSettings::Front::EcoLadderGantryMetalIncome)
            return Front_LadderGantryHeld("metal income +" + int(mi) + " of " + int(Global::RoleSettings::Front::EcoLadderGantryMetalIncome)
                + " | advanced fusions " + FrontEcoLadder::AdvFusions() + "/" + FrontEcoLadder::AdvFusionsTotal());
        if (g_frontGantryAllowance < 1) g_frontGantryAllowance = 1;
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllGantries(), g_frontGantryAllowance);
        dictionary mapLimits = Global::Map::Config.UnitLimits;   // map limits win
        UnitHelpers::ApplyUnitLimits(mapLimits);
        if (!gantry.IsAvailable(ai.frame))
            return Front_LadderGantryHeld(gantry.GetName() + " unavailable (count " + gantry.count + ", cap " + gantry.maxThisUnit + ")");
        AIFloat3 site;
        bool sited = Front_LadderGantrySite(gantry, site);
        float shake = SQUARE_SIZE * 4;
        if (!sited) {
            // no reservable footprint found: the engine places it itself, round the next fallback anchor
            site = Front_LadderGantryFallback(g_frontLadderGantryTry++);
            shake = SQUARE_SIZE * 48;
        }
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NOW, gantry, site, gantry, shake, false, true, 600 * SECOND));
        if (t is null) {
            g_frontLadderGantryRetry = ai.frame + 60 * SECOND;
            GenericHelpers::LogUtil("[FRONT][Eco] gantry could not be ordered at " + int(site.x) + "," + int(site.z) + (sited ? "" : " (engine-sited, try " + g_frontLadderGantryTry + ")") + "; retry in 60 s", 1);
            return null;
        }
        Builder::MarkGantryEnqueued();
        @g_frontLadderGantryTask = t; g_frontLadderGantrySite = site;
        GenericHelpers::LogUtil("[FRONT][Eco] gantry " + gantry.GetName() + " ordered at " + int(site.x) + "," + int(site.z) + (sited ? " (reserved site)" : " (engine-sited, try " + g_frontLadderGantryTry + ")")
            + " | M +" + int(mi) + " bank " + int(aiEconomyMgr.metal.current) + " by " + u.circuitDef.GetName() + " " + u.id, 1);
        return t;
    }

    void Front_IncomeBuilderLimits(float metalIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int t1BuilderCap = 5 * int(metalIncome / Global::RoleSettings::Front::MetalIncomePerT1Builder);
        if (t1BuilderCap < Global::RoleSettings::Front::MinBuilderCap) t1BuilderCap = Global::RoleSettings::Front::MinBuilderCap;

        string side = Global::AISettings::Side;
        
        // T1 Builders
        array<string> t1Builders = UnitHelpers::GetT1LandBuilders(side);
        UnitHelpers::BatchApplyUnitCaps(t1Builders, t1BuilderCap);

        // T2 Builder Cap Logic
        int t2BuilderCap = 5 * int(metalIncome / Global::RoleSettings::Front::MetalIncomePerT2Builder);
        if (t2BuilderCap < Global::RoleSettings::Front::MinBuilderCap) t2BuilderCap = Global::RoleSettings::Front::MinBuilderCap;

        // T2 Builders
        array<string> t2Builders = UnitHelpers::GetT2LandBuilders(side);
        UnitHelpers::BatchApplyUnitCaps(t2Builders, t2BuilderCap);
    }

    void Front_IncomeNanoLimits(float energyIncome) {
        int nanoCap = int(energyIncome / Global::RoleSettings::Front::NanoEnergyPerUnit);
        
        if (nanoCap < Global::RoleSettings::Front::NanoMinCount) {
            nanoCap = Global::RoleSettings::Front::NanoMinCount;
        }

        if (energyIncome > Global::RoleSettings::Front::NanoEnergyIncomeThresholdForMax) {
            nanoCap = Global::RoleSettings::Front::NanoMaxCount;
        }
        array<string> nanos = UnitHelpers::GetT1NanoUnitNames();
        UnitHelpers::BatchApplyUnitCaps(nanos, nanoCap);
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/ 

    // Helper to attempt building a T1 nano caretaker
    IUnitTask@ Front_TryBuildNano(float metalIncome) {
        float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
            ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
            : 0.0f;

        // Primary condition: reserves-based gate (legacy behavior).
        bool allowByReserves = EconomyHelpers::ShouldBuildT1Nano_ByReserves(
            /*metalCurrent*/ aiEconomyMgr.metal.current,
            /*buildWhenOverMetal*/ Global::RoleSettings::Front::NanoBuildWhenOverMetal,
            /*energyPercent*/ energyPercent
        );

        // Secondary condition: early construction turret allowance when
        // income is above a small threshold but we have no nanos yet.
        // This lets us get the first nano online without needing a big
        // metal stockpile, while still preventing early over-spam.
        int existingNanos = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetT1NanoUnitNames());
        bool allowFirstNanoByIncome = (metalIncome > Global::RoleSettings::Front::NanoMinIncomeForFirst && existingNanos < 1);

        if (allowByReserves || allowFirstNanoByIncome) {
            CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
            if (targetFactory !is null) {
                IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::HIGH);
                if (tNano !is null) return tNano;
            }
        }
        return null;
    }

    IUnitTask@ Front_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyStalling, bool isEnergyFull) {
        // Econ snapshot is passed by caller (min over last 10s for incomes)

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Primary constructor branch (Bots)
        if (u is Builder::primaryT1BotConstructor) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

            // Fast-track: if we have zero T2 bot labs and ANY trigger is met, build a T2 Bot Lab now.
            // Triggers (OR):
            //  1) metal income >= configured threshold
            //  2) game time >= 22 minutes
            //  3) stored metal >= T2 bot lab cost
            if (t2LabCount < 1) {
                const float incomeTrigger = Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
                const bool timeTriggerMet = (ai.frame >= (Global::RoleSettings::Front::TimeTriggerForFirstT2LabSeconds * SECOND));
                const bool incomeTriggerMet = (metalIncome >= incomeTrigger);
                // Resolve T2 lab cost for stored-metal trigger
                bool storedMetalTriggerMet = false;
                string t2LabName = UnitHelpers::GetT2BotLabForSide(unitSide);
                CCircuitDef@ t2LabDef = ai.GetCircuitDef(t2LabName);
                if (t2LabDef !is null) {
                    storedMetalTriggerMet = (aiEconomyMgr.metal.current >= (t2LabDef.costM * Global::RoleSettings::Front::T2LabStoredMetalThresholdRatio));
                }
                if (incomeTriggerMet || timeTriggerMet || storedMetalTriggerMet) {
                    AIFloat3 anchor2 = Factory::GetT1BotLabPos();
                    IUnitTask@ t2b = Builder::EnqueueT2BotLabIfNeeded(unitSide, anchor2, SQUARE_SIZE * 30, SECOND * 300);
                    if (t2b !is null) return t2b;
                }
            }

            // Transition to vehicles if metal income > threshold and no vehicle plant
            int t1VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1VehicleLabs());
            if (metalIncome > Global::RoleSettings::Front::MinimumMetalIncomeForT1FactoryTransition && t1VehLabCount < 1) {
                AIFloat3 pos = Factory::GetPreferredFactoryPos();
                IUnitTask@ tVeh = Builder::EnqueueT1VehiclePlant(unitSide, pos, SQUARE_SIZE * 24, 600 * SECOND);
                if (tVeh !is null) return tVeh;
            }

            // Try T2 lab if eco allows
            bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLab(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*metalCurrent*/ aiEconomyMgr.metal.current,
                /*requiredMetalIncome*/ Global::RoleSettings::Front::MinimumMetalIncomeForT2Lab,
                /*requiredMetalCurrent*/ Global::RoleSettings::Front::RequiredMetalCurrentForT2Lab,
                /*requiredEnergyIncome*/ Global::RoleSettings::Front::MinimumEnergyIncomeForT2Lab,
                /*constructorDef*/ u.circuitDef,
                /*t2BotLabCount*/ t2LabCount,
                /*maxAllowed*/ Global::RoleSettings::Front::MaxT2BotLabs,
                /*hasPrimaryFactory*/ (Factory::primaryT1BotLab !is null)
            );

            if (shouldT2Lab) {
                // Place near our T1 Bot Lab (or commander fallback via Factory)
                AIFloat3 anchor = Factory::GetT1BotLabPos();
                IUnitTask@ tLab = Builder::EnqueueT2BotLabIfNeeded(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 300);
                if (tLab !is null) return tLab;
            }

            // After T2 lab attempt: build a T1 nano caretaker when either reserves allow
            // it or we're early-game with sufficient income and zero existing nanos.
            // Route through centralized per-factory nano selection and enqueue helpers.
            IUnitTask@ tNano = Front_TryBuildNano(metalIncome);
            if (tNano !is null) return tNano;

        }

        // Primary constructor branch (Vehicles)
        if (u is Builder::primaryT1VehConstructor) {
            int t2VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs());
            
            // Fast-track: if we have zero T2 vehicle labs and ANY trigger is met, build a T2 Vehicle Plant now.
            if (t2VehLabCount < 1) {
                const float incomeTrigger = Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2VehiclePlant;
                const bool timeTriggerMet = (ai.frame >= (Global::RoleSettings::Front::TimeTriggerForFirstT2LabSeconds * SECOND));
                const bool incomeTriggerMet = (metalIncome >= incomeTrigger);
                
                // Resolve T2 vehicle lab cost for stored-metal trigger
                bool storedMetalTriggerMet = false;
                string t2VehName = "";
                if (unitSide == "armada") t2VehName = "armavp";
                else if (unitSide == "cortex") t2VehName = "coravp";
                else if (unitSide == "legion") t2VehName = "legavp";
                
                if (t2VehName != "") {
                    CCircuitDef@ t2VehDef = ai.GetCircuitDef(t2VehName);
                    if (t2VehDef !is null) {
                        storedMetalTriggerMet = (aiEconomyMgr.metal.current >= (t2VehDef.costM * Global::RoleSettings::Front::T2LabStoredMetalThresholdRatio));
                    }
                }

                if (incomeTriggerMet || timeTriggerMet || storedMetalTriggerMet) {
                    IUnitTask@ tVeh2 = Builder::EnqueueT2VehiclePlant(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                    if (tVeh2 !is null) return tVeh2;
                }
            }

            // Transition to bots if metal income > threshold and no bot lab
            int t1BotLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotLabs());
            if (metalIncome > Global::RoleSettings::Front::MinimumMetalIncomeForT1FactoryTransition && t1BotLabCount < 1) {
                AIFloat3 pos = Factory::GetPreferredFactoryPos();
                IUnitTask@ tBot = Builder::EnqueueT1BotLab(unitSide, pos, SQUARE_SIZE * 24, 600 * SECOND);
                if (tBot !is null) return tBot;
            }
            
            // Try building nano
            IUnitTask@ tNano = Front_TryBuildNano(metalIncome);
            if (tNano !is null) return tNano;

            // No special vehicle-only eco tasks for now; default
            return defaultTask;
        }

        return defaultTask;
    }

    IUnitTask@ Front_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        // Copy of TECH T2 constructor logic with Front-specific gating:
        // - Before 20 minutes of game time, force eco: only build energy converter/AFUS/FUS (skip gantry/nuke/anti-nuke)
        // - After 20 minutes, allow full TECH-style sequence (gantry, nuke, anti-nuke, etc.)

        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Freelance T2 constructors just do default tasks
        if (u is Builder::freelanceT2BotConstructor) {
            return defaultTask;
        }

        const bool isPrimary = (u is Builder::primaryT2BotConstructor || u is Builder::primaryT2VehConstructor);
        const bool isSecondary = (u is Builder::secondaryT2BotConstructor);

        AIFloat3 anchor = Global::Map::StartPos;

        // Eco gating: force economy builds for the first 20 minutes
        const bool forceEco = (ai.frame < (Global::RoleSettings::Front::TimeTriggerForT2EcoGatingSeconds * SECOND));

        if (isPrimary && !FrontEcoLadder::On()) {   // Front::EcoLadder owns the reactors when on
            // Fusion Reactor
            if (EconomyHelpers::ShouldBuildFusionReactor(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*reqMi*/ Global::RoleSettings::Front::MinimumMetalIncomeForFUS,
                /*reqEi*/ Global::RoleSettings::Front::MinimumEnergyIncomeForFUS,
                /*maxEi*/ Global::RoleSettings::Front::MaxEnergyIncomeForFUS
            )) {
                IUnitTask@ tFus2 = Builder::EnqueueFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus2 !is null) return tFus2;
            }
        } 

        return defaultTask;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Front_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::FRONT) match = true;
       
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] FRONT", 2); 
        }

        return match;
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::FRONT) !is null) return; // already
        RoleConfig@ cfg = RoleConfig(AiRole::FRONT, cast<MainUpdateDelegate@>(@Front_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Front_Init);
       
        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Front_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Front_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Front_MakeSwitchInterval);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_FactoryAiMakeTask);

        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_BuilderAiUnitRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Front_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Front_BuilderAiTaskRemoved);

        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Front_EconomyUpdate);
       
        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Front_SelectFactoryHandler);
        @cfg.FactoryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_FactoryAiUnitAdded);
        @cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_FactoryAiUnitRemoved);
        @cfg.FactoryAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@FrontOpener::RecruitRemoved);
        @cfg.MilitaryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_MilitaryAiMakeTask);
        @cfg.MilitaryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@FrontOpener::UnitRemoved);
        @cfg.MilitaryAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@FrontOpener::TaskRemoved);

        @cfg.MilitaryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_MilitaryAiUnitAdded);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Front_RoleMatch);

        RoleConfigs::Register(cfg);
    }
}
