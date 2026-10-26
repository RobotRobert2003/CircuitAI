// role: SEA
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/construction/economy_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../types/role_config.as"
#include "../../global.as"
#include "../../types/terrain.as"
#include "../../helpers/objectives/objective_helpers.as"
#include "../../helpers/construction/sea_constructor_helpers.as"
#include "sea_build.as"
#include "../../systems/sea/sea_recovery.as"
#include "../../systems/sea/sea_invasion.as"
#include "../../systems/sea/sea_coast.as"

namespace RoleSea {

    // Donation helper state and functions (mirror TECH pattern but for T2 sea constructors)
    namespace Donate {
        // Count of T2 constructor submarines ever produced by SEA role
        int T2SeaCtorEverBuilt = 0;
        // Ensure we donate only once per game
        bool DonatedThird = false;

        // Return true if the def represents a T2 sea constructor submarine
        bool IsT2SeaConstructor(const CCircuitDef@ d) {
            if (d is null) return false;
            const string n = d.GetName();
            // T2 sea constructors (BAR): armacsub/coracsub; Legion reuses Cortex variant
            return (n == "armacsub" || n == "coracsub");
        }

        // Attempt to donate a unit to the lead team; logs and guards
        void TryDonate(CCircuitUnit@ u) {
            if (u is null) return;
            const int leader = ai.GetLeadTeamId();
            if (ai.teamId == leader) {
                GenericHelpers::LogUtil("[SEA][Donate] We are the leader team; skip donation for unit id=" + u.id, 3);
                return; // no-op when this AI is the leader
            }

            array<CCircuitUnit@> give(1);
            @give[0] = u; // valid handle this frame
            ai.GiveUnits(give, leader);
            GenericHelpers::LogUtil("[SEA][Donate] Transferred unit id=" + u.id + " to team " + leader, 2);
        }
    }

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/

    void Sea_Init() {
        aiBuilderMgr.recoverConstruction = true;
        SeaInvasion::Init();
        SeaRecovery::Reset();
        GenericHelpers::LogUtil("Sea role initialization logic executed", 2);

        // Apply SEA role settings
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Sea::AllyRange);
        // Change scout cap (unit count)
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Sea::MilitaryScoutCap;

        // Change attack gate (power threshold, not a headcount)
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Sea::MilitaryAttackThreshold;

        // Waves: reachable-threat bar and a wait cap (see Global::Military)
        aiMilitaryMgr.quota.attackWait = Global::RoleSettings::Sea::MilitaryAttackWaitSeconds;
        aiMilitaryMgr.quota.attackScale = Global::RoleSettings::Sea::MilitaryAttackScale;

        // Change raid thresholds (power)
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Sea::MilitaryRaidMinPower; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Sea::MilitaryRaidAvgPower; 

        Sea_ApplyStartLimits();

        // Missing factory metadata must be registered on this SEA instance,
        // not by changing shared profiles used by other roles.
        if (Global::RoleSettings::Sea::SeaplanesAfterT2) {
            CCircuitDef@ platform=ai.GetCircuitDef("legsplab");
            if (platform !is null) aiFactoryMgr.RegisterScriptFactory(platform,ai.GetCircuitDef("corplat"));
        }

        // Some experimental profiles omit the Legion advanced shipyard from
        // native factory metadata. SEA's opt-in must register it before a
        // frame exists; otherwise the finished yard never receives a task.
        // InitHandler precedes LayoutPlanHandler, which sets Layout::enabled.
        if (Global::RoleSettings::Sea::ExperimentalBuild || Global::RoleSettings::Sea::AdaptiveFleet) {
            CCircuitDef@ yard=ai.GetCircuitDef("legadvshipyard");
            if (yard !is null && aiFactoryMgr.RegisterScriptFactory(yard,ai.GetCircuitDef("corasy"))) {
                Factory::userData[yard.id].attr |= Factory::Attr::T2;
                GenericHelpers::LogUtil("[SEA][Factory] Legion T2 runtime metadata ready",1);
            }
        }

        // SEA-only: Set default fire state for all T1 naval combat units to 3 (fire at everything)
        // Aligns with FRONT role pattern for T1 land units.
        {
            array<string> t1Naval = UnitHelpers::GetAllT1NavalCombatUnits();
            for (uint i = 0; i < t1Naval.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(t1Naval[i]);
                if (d is null) continue;
                d.SetFireState(3);
            }
            GenericHelpers::LogUtil("[SEA] Applied default fire state=3 to T1 naval combat units", 3);
        }

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::SEA, "SEA");
    }

    void Sea_ApplyStartLimits() {
        dictionary startLimits; 

        startLimits.set("armbanth", 0);
        // D-212's SEA-owned amphibious factories need their invasion products.
        // Map-specific restrictions are still applied by the shared setup.
        if (!Global::RoleSettings::Sea::AmphibiousInvasion) {
            startLimits.set("armmar", 0);
            startLimits.set("armcroc", 0);
        }

        startLimits.set("armsilo", 0);
        startLimits.set("corsilo", 0);
        startLimits.set("legsilo", 0);

        UnitHelpers::ApplyUnitLimits(startLimits);

    GenericHelpers::LogUtil("Tactical start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    // Compute the total metal "power" of all SEA army units using the military manager's armyCost.
    float Sea_GetArmyMetalCostEstimate()
    {
        float armyCost = aiMilitaryMgr.armyCost;
        if (!(armyCost == armyCost) || armyCost < 0.f) {
            armyCost = 0.f;
        }
        return armyCost;
    }

    // Adjust SEA military quotas based on comparison of our army metal cost vs cached enemy water cost.
    void Sea_UpdateDynamicMilitaryQuotas()
    {
        // Estimate our army metal cost
        float ourArmyCost = Sea_GetArmyMetalCostEstimate();

        // Enemy water metrics (cost per player) are cached centrally in Military
        float enemyWaterCostPerPlayer = Military::GetEnemyWaterCostPerPlayer();
        float enemyWaterCostTotal     = Military::g_cachedTotalWaterCost; // for logging only

        // Defensive sanity checks
        if (!(enemyWaterCostPerPlayer == enemyWaterCostPerPlayer) || enemyWaterCostPerPlayer < 0.f) {
            enemyWaterCostPerPlayer = 0.f;
        }

        float threshold = enemyWaterCostPerPlayer * Global::RoleSettings::Sea::DynamicQuotaEnemyCostThresholdMultiplier;

        bool isUnderpowered = (ourArmyCost < threshold);

        // When underpowered vs enemy water cost, push quotas high to encourage more army production.
        if (isUnderpowered) {
            // Use a high cap and low attack threshold to trigger more frequent waves.
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Sea::UnderpoweredAttackQuota;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Sea::UnderpoweredRaidMinQuota;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Sea::UnderpoweredRaidAvgQuota;

            GenericHelpers::LogUtil(
                "[SEA][Quota] Underpowered vs enemy water (ourArmyCost=" + ourArmyCost +
                " enemyWaterCostTotal=" + enemyWaterCostTotal +
                " enemyWaterPerPlayer=" + enemyWaterCostPerPlayer +
                " thr=" + threshold +
                ") => HIGH quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                3
            );
        } else {
            // When not underpowered, keep quotas near their sea-role defaults.
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Sea::MilitaryScoutCap;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Sea::MilitaryAttackThreshold;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Sea::MilitaryRaidMinPower;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Sea::MilitaryRaidAvgPower;

            GenericHelpers::LogUtil(
                "[SEA][Quota] Competitive vs enemy water (ourArmyCost=" + ourArmyCost +
                " enemyWaterCostTotal=" + enemyWaterCostTotal +
                " enemyWaterPerPlayer=" + enemyWaterCostPerPlayer +
                " thr=" + threshold +
                ") => BASE quotas: scout=" + aiMilitaryMgr.quota.scout +
                " attack=" + aiMilitaryMgr.quota.attack +
                " raid.min=" + aiMilitaryMgr.quota.raid.min +
                " raid.avg=" + aiMilitaryMgr.quota.raid.avg,
                4
            );
        }
    }

    void Sea_MainUpdate() {
        SeaRecovery::Tick();
        if (SeaLayout::Enabled()) SeaBuild::Tick();
        SeaCombat::Tick();
        SeaCoast::Tick();
        SeaExpansion::Tick();
        SeaInvasion::Tick();
        if (SeaCombat::Active()) return;
        // Delay dynamic quota adjustments until configured time into the game
        if (ai.frame < (Global::RoleSettings::Sea::DynamicQuotaDelaySeconds * SECOND)) {
            return;
        }
        Sea_UpdateDynamicMilitaryQuotas();
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Sea_EconomyUpdate() {
    float metalIncome = aiEconomyMgr.metal.income;
        Sea_IncomeLimits(metalIncome);
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    IUnitTask@ Sea_FactoryAiMakeTask(CCircuitUnit@ u)
    {
        IUnitTask@ invasion=SeaInvasion::Produce(u);
        if (invasion !is null) return invasion;
        if (u !is null && Global::RoleSettings::Sea::SeaplanesAfterT2 && UnitHelpers::IsSeaplanePlatform(u.circuitDef.GetName()))
            return aiFactoryMgr.MakeFactoryTask(u,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
        if (SeaLayout::Active()) return SeaFactories::Produce(u);
        const CCircuitDef@ facDef = (u is null ? null : u.circuitDef);
        if (facDef is null) {
            return aiFactoryMgr.MakeFactoryTask(u,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
        }

        const string fname = facDef.GetName();
        // Only specialize for shipyards; otherwise fallback
        bool isT1Shipyard = UnitHelpers::IsT1Shipyard(fname);
        bool isT2Shipyard = (!isT1Shipyard && UnitHelpers::IsT2Shipyard(fname));
        if (!isT1Shipyard && !isT2Shipyard) {
            return aiFactoryMgr.MakeFactoryTask(u,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        const string side = UnitHelpers::GetSideForUnitName(fname);

        // Resolve side-specific constructor unit names (with safe fallbacks)
        string t1Ctor = (side == "armada" ? "armcs" : side == "cortex" ? "corcs" : side == "legion" ? "legnavyconship" : "armcs");
        string t2Ctor = SeaEconomy::Constructor(side,true);

        // Keep the selected economic builder path. Emergency combat selection
        // is independent of layouts and follows one recovery constructor.
        if (SeaCombat::Active()) {
            CCircuitDef@ con=ai.GetCircuitDef(isT1Shipyard ? t1Ctor : t2Ctor);
            const int workers=con is null ? 0 : con.count+aiFactoryMgr.GetPendingRecruitCount(con);
            if (workers>=1) {
                CCircuitDef@ counter=SeaCombat::Select(u,true);
                if (counter !is null) return SeaFactories::Recruit(u,counter,Task::RecruitType::FIREPOWER,false,true);
            }
            // D-300: bank for the first advanced yard; counters above still run.
            if (isT1Shipyard && workers>=2 && SeaEconomy::TechHold())
                return aiFactoryMgr.Enqueue(TaskS::Wait(false,3*SECOND));
            if (workers>=2) {
                IUnitTask@ workforce=SeaFactories::Workforce(u);
                if (workforce !is null) return workforce;
                IUnitTask@ utility=SeaFactories::Utility(u);
                if (utility !is null) return utility;
                CCircuitDef@ combat=SeaCombat::Select(u);
                if (combat !is null) return SeaFactories::Recruit(u,combat,Task::RecruitType::FIREPOWER);
            }
        }

        if (isT1Shipyard) {
            // Ensure at least two T1 construction ships exist before producing other units
            int have = UnitDefHelpers::GetUnitDefCount(t1Ctor);
            if (have < 2) {
                CCircuitDef@ d = ai.GetCircuitDef(t1Ctor);
                if (d !is null && d.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d, pos, 64.f)
                    );
                }
            }

            // Constructor guarantee logic continues below
            have = UnitDefHelpers::GetUnitDefCount(t1Ctor);
            if (have < 2) {
                CCircuitDef@ d = ai.GetCircuitDef(t1Ctor);
                if (d !is null && d.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d, pos, 64.f)
                    );
                }
            }

            // Early resurrection submarine policy (configurable)
            // Gate by global setting and income-scaling helper, similar to early bot-lab expansion in TECH
            if (Global::RoleSettings::Sea::EnableEarlyRezSub) {
                float mi = aiEconomyMgr.metal.income;
                // Side IDs: armada -> armrecl, cortex -> correcl, legion -> legnavyrezsub (Dionysus)
                string rezSub = (side == "armada" ? "armrecl" : side == "cortex" ? "correcl" : "legnavyrezsub");
                int haveRez = UnitDefHelpers::GetUnitDefCount(rezSub);
                bool shouldRez = EconomyHelpers::ShouldBuildT1ResurrectionSub(
                    /*metalIncome*/ mi,
                    /*currentRezSubCount*/ haveRez,
                    /*metalIncomePerRezSub*/ Global::RoleSettings::Sea::MetalIncomePerRezSub,
                    /*earlyEnabled*/ Global::RoleSettings::Sea::EnableEarlyRezSub
                );
                if (shouldRez) {
                    CCircuitDef@ dRez = ai.GetCircuitDef(rezSub);
                    if (dRez !is null && dRez.IsAvailable(ai.frame)) {
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dRez, pos, 64.f)
                        );
                    }
                }
            }
        }

        if (isT2Shipyard) {
            // Ensure at least one T2 sea constructor exists early
            int t2conSubCount = UnitDefHelpers::GetUnitDefCount(t2Ctor);
            if (t2conSubCount < 2) {
                CCircuitDef@ d2 = ai.GetCircuitDef(t2Ctor);
                if (d2 !is null && d2.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d2, pos, 64.f)
                    );
                }
            }

            // T2 shipyard production policy (configurable counts per class)
            // 1) Destroyers (T2/cruiser-tier): if below target, enqueue a batch at NORMAL priority
            string destroyerName = UnitHelpers::GetNavalT2DestroyerNameForSide(side);
            int haveDestroyers = UnitDefHelpers::GetUnitDefCount(destroyerName);
            int minDestroyers = Global::RoleSettings::Sea::MinT2DestroyerCount;
            int destroyerBatch = Global::RoleSettings::Sea::T2DestroyerBatchSize;
            if (minDestroyers > 0 && haveDestroyers >= 0 && haveDestroyers < minDestroyers && destroyerBatch > 0) {
                CCircuitDef@ d = ai.GetCircuitDef(destroyerName);
                if (d !is null && d.IsAvailable(ai.frame)) {
                    IUnitTask@ first = null;
                    int toQueue = destroyerBatch;
                    for (int i = 0; i < toQueue; ++i) {
                        IUnitTask@ t = aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d, pos, 64.f)
                        );
                        if (first is null) @first = t;
                    }
                    if (first !is null) return first;
                }
            }

            // 2) AA ships (flak/escort): if below 2, enqueue 2
            string aaShipName = UnitHelpers::GetNavalAAShipNameForSide(side);
            int haveAA = UnitDefHelpers::GetUnitDefCount(aaShipName);
            if (haveAA >= 0 && haveAA < 2) {
                CCircuitDef@ dAA = ai.GetCircuitDef(aaShipName);
                if (dAA !is null && dAA.IsAvailable(ai.frame)) {
                    IUnitTask@ firstAA = null;
                    for (int i = 0; i < 2; ++i) {
                        IUnitTask@ tAA = aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dAA, pos, 64.f)
                        );
                        if (firstAA is null) @firstAA = tAA;
                    }
                    if (firstAA !is null) return firstAA;
                }
            }

            // 3) Jammer ship: ensure at least 1
            string jammerName = UnitHelpers::GetNavalJammerShipNameForSide(side);
            int haveJammers = UnitDefHelpers::GetUnitDefCount(jammerName);
            if (haveJammers >= 0 && haveJammers < 1) {
                CCircuitDef@ dJam = ai.GetCircuitDef(jammerName);
                if (dJam !is null && dJam.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dJam, pos, 64.f)
                    );
                }
            }

            // 4) Radar ship (MLS utility): ensure at least 1
            string radarShipName = UnitHelpers::GetNavalRadarShipNameForSide(side);
            int haveRadar = UnitDefHelpers::GetUnitDefCount(radarShipName);
            if (haveRadar >= 0 && haveRadar < 1) {
                CCircuitDef@ dRad = ai.GetCircuitDef(radarShipName);
                if (dRad !is null && dRad.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dRad, pos, 64.f)
                    );
                }
            }

            // 5) Missile ships: if below 5, enqueue 5
            string mShipName = UnitHelpers::GetNavalMissileShipNameForSide(side);
            int haveMissile = UnitDefHelpers::GetUnitDefCount(mShipName);
            if (haveMissile >= 0 && haveMissile < 5) {
                CCircuitDef@ dMs = ai.GetCircuitDef(mShipName);
                if (dMs !is null && dMs.IsAvailable(ai.frame)) {
                    IUnitTask@ firstMs = null;
                    for (int i = 0; i < 5; ++i) {
                        IUnitTask@ tMs = aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dMs, pos, 64.f)
                        );
                        if (firstMs is null) @firstMs = tMs;
                    }
                    if (firstMs !is null) return firstMs;
                }
            }

            // 6) Anti-nuke ship: ensure at least 1 (skip gracefully if not available in profile)
            string antiNukeShip = UnitHelpers::GetNavalAntiNukeShipNameForSide(side);
            int haveAnti = UnitDefHelpers::GetUnitDefCount(antiNukeShip);
            if (haveAnti >= 0 && haveAnti < 1) {
                CCircuitDef@ dAnti = ai.GetCircuitDef(antiNukeShip);
                if (dAnti !is null && dAnti.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dAnti, pos, 64.f)
                    );
                }
            }

            // 7) Flagship (capital ship): ensure at least 1, placed last in sequence
            // Side IDs: armada -> armepoch, cortex -> corblackhy; Legion falls back to Cortex variant
            string flagshipName = (side == "armada" ? "armepoch" : (side == "cortex" ? "corblackhy" : "corblackhy"));
            int haveFlagship = UnitDefHelpers::GetUnitDefCount(flagshipName);
            if (haveFlagship >= 0 && haveFlagship < 1) {
                CCircuitDef@ dFlag = ai.GetCircuitDef(flagshipName);
                if (dFlag !is null && dFlag.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, dFlag, pos, 64.f)
                    );
                }
            }
        }

        // Fallback to default when nothing triggers
        return aiFactoryMgr.MakeFactoryTask(u,true,Global::RoleSettings::Sea::KeepFactoriesQueued);
    }

    string Sea_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {

        if(isStart) {
            if(Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Sea_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
        }
        
        return "";
    }

    bool Sea_AiIsSwitchTime(int lastSwitchFrame) {
        int interval = (30 * SECOND);
        return (lastSwitchFrame + interval) <= ai.frame;
    }

    bool Sea_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        if (!SeaFactories::FactoryAllowed(facDef)) { assistRequired=false; return false; }
        const bool isOK = (armyCost > 1.2f * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        assistRequired = !isOK;
        return isOK;
    }

    int Sea_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Sea::MinAiSwitchTime, Global::RoleSettings::Sea::MaxAiSwitchTime) * SECOND;
    }

    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    IUnitTask@ Sea_BuilderAiMakeTask(CCircuitUnit@ builder) {
        IUnitTask@ coastal=SeaCoast::Build(builder);
        if (coastal !is null) return coastal;
        if (builder !is null && SeaRecovery::IsSub(builder.circuitDef)) return SeaRecovery::Make(builder);
        IUnitTask@ commander=SeaBuild::Commander(builder);
        if (commander !is null) return commander;
        // Run before native default-task creation: it may enqueue discretionary
        // converters/guards even when the first ship has free reachable metal.
        IUnitTask@ mex=SeaBuild::OpeningMex(builder);
        if (mex !is null) return mex;
        if (builder !is null && (builder.task is null || (!builder.task.IsEnemyReclaim()
            && builder.task.GetType()!=int(Task::Type::PLAYER) && builder.task.GetType()!=int(Task::Type::RETREAT)))) {
            IBuilderTask@ current=cast<IBuilderTask>(builder.task);
            if (current is null || current.IsDead() || current.GetBuildType()>=int(Task::BuildType::REPAIR)) {
                IUnitTask@ invasion=SeaInvasion::Build(builder); if (invasion !is null) return invasion;
            }
        }
        if (SeaLayout::Active()) return SeaBuild::MakeTask(builder);
        if (SeaLayout::Enabled()) return SeaBuild::LegacyTask(builder);
        if (builder !is null && (builder.task is null || (!builder.task.IsEnemyReclaim()
            && builder.task.GetType()!=int(Task::Type::PLAYER)))) {
            IBuilderTask@ current=cast<IBuilderTask>(builder.task);
            if (current is null || current.IsDead() || current.GetBuildType()>=int(Task::BuildType::REPAIR)) {
                IUnitTask@ platform=SeaBuild::Seaplane(builder); if (platform !is null) return platform;
            }
        }
        return Sea_LegacyBuilderTask(builder);
    }

    IUnitTask@ Sea_LegacyBuilderTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Sea_BuilderAiMakeTask] called for builder", 3);
        if (builder is null) return null; // Defensive

        // Pre-create and cache a single default task instance; never recreate.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "SEA");

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return defaultTask;

        // Early resource-expansion return: preserve MEX/GEO build tasks
        IBuilderTask@ defaultBuilderTask = cast<IBuilderTask>(defaultTask);
        if (defaultBuilderTask !is null) {
            Task::BuildType dbt = Task::BuildType(defaultBuilderTask.GetBuildType());
            if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
                dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP ||
                dbt == Task::BuildType::ENERGY) {
                GenericHelpers::LogUtil("[FRONT] defaultTask is MEX/MEXUP/GEO/GEOUP/ENERGY; returning early", 3);
                return defaultTask;
            }
        }

        // Commander-specific logic: delegate to commander builder logic when applicable.
        bool isCommander = UnitHelpers::IsCommander(udef);
        if (isCommander) {
            return Sea_Commander_AiMakeTask(builder, defaultTask);
        }

        // Specialize only sea constructors; everything else falls back to cached default
        string uname = udef.GetName();
        // Include Legion's non-standard T1 constructor name explicitly (no 'cs' suffix)
        // By the unit-helper lists: the old "acsub" suffix test missed Legion's
        // leganavyconsub, which then only ever got the default task.
        bool isT1SeaConstructor = SeaConstructor::IsT1(udef);
        bool isT2SeaConstructor = SeaConstructor::IsT2(udef);

        if (isT1SeaConstructor) {
            return Sea_T1Constructor_AiMakeTask(builder, defaultTask);
        } else if (isT2SeaConstructor) {
            return Sea_T2Constructor_AiMakeTask(builder, defaultTask);
        }

        // Fallback to cached default task
        return defaultTask;
    }

    /******************************************************************************

    BUILDER LOGIC (COMMANDER)

    ******************************************************************************/ 

    // For the early game window, keep the commander assigned to guard
    // the primary T1 shipyard (if present). Do NOT apply this to land factories.
    IUnitTask@ Sea_Commander_AiMakeTask(CCircuitUnit@ comm, IUnitTask@ defaultTask)
    {
        if (comm is null) return defaultTask;

        // Configurable deadline (in frames) after which the commander stops
        // prioritizing factory assist and falls back to default behavior.
        const int SEA_FACTORY_ASSIST_DEADLINE_FRAMES = Global::RoleSettings::Sea::CommanderFactoryAssistDeadlineSeconds * SECOND;
        if (ai.frame > SEA_FACTORY_ASSIST_DEADLINE_FRAMES) {
            // After the early window, fall back to default behavior
            return defaultTask;
        }

        // D-352: the land spots inside the home radius are this seat's (rule 1);
        // the commander takes them before it assists the yard. Native admission
        // owns reach and occupancy, so a water start simply finds nothing.
        if (Team::MexClaim::Enabled() && comm.task is null
            && aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, Team::MexClaim::HomeRadius()) < 1) {
            IUnitTask@ home = aiEconomyMgr.EnqueueMexWithin(comm, Global::Map::StartPos, Team::MexClaim::HomeRadius(), 0, true);
            if (home !is null) return home;
        }
        // Prefer guarding the primary T1 shipyard only.
        CCircuitUnit@ target = null;
        if (Factory::primaryT1Shipyard !is null) {
            @target = Factory::primaryT1Shipyard;
        }

        if (target is null) {
            // No suitable factory yet; let normal builder/commander logic handle this frame
            return defaultTask;
        }

        // Assign a high-priority guard task so the commander sticks near the sea factory.
        // The guard timeout is configurable via role settings.
        const int SEA_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES = Global::RoleSettings::Sea::CommanderFactoryAssistGuardTimeoutSeconds * SECOND;
        IUnitTask@ guardTask = GuardHelpers::AssignWorkerGuard(
            comm,
            target,
            Task::Priority::HIGH,
            true,
            SEA_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES // guard duration; can be renewed while within deadline
        );

        return (guardTask !is null ? guardTask : defaultTask);
    }

    void Sea_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Sea_BuilderAiTaskAdded] called for task", 3);
    }

    void Sea_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {
        //GenericHelpers::LogUtil("[Sea_BuilderAiTaskRemoved] called for task", 3);
    }

    CCircuitUnit@ energizer1 = null;
	CCircuitUnit@ energizer2 = null;
    void Sea_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		SeaRecovery::Added(unit);
		SeaExpansion::Added(unit);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

        // Donation hook: when the 3rd T2 sea constructor is created, donate it to the team leader (once per game)
        if (Donate::IsT2SeaConstructor(cdef)) {
            Donate::T2SeaCtorEverBuilt += 1;
            GenericHelpers::LogUtil("[SEA][Donate] T2 sea constructor observed (" + cdef.GetName() + ") count=" + Donate::T2SeaCtorEverBuilt + " id=" + unit.id, 3);
            if (!Donate::DonatedThird && Donate::T2SeaCtorEverBuilt == 3) {
                Donate::DonatedThird = true; // lock before attempt to avoid re-entry
                GenericHelpers::LogUtil("[SEA][Donate] Triggering donation of 3rd T2 sea constructor (id=" + unit.id + ")", 2);
                Donate::TryDonate(unit);
            }
        }

		// constructor with BASE attribute is assigned to tasks near base
		if (cdef.costM < 200.f) {
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

    void Sea_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		SeaRecovery::Removed(unit);
        SeaExpansion::Removed(unit);
		if (energizer1 is unit)
			@energizer1 = null;
		else if (energizer2 is unit)
			@energizer2 = null;
	}

    /******************************************************************************

    ECONOMY LOGIC

    ******************************************************************************/

    void Sea_IncomeLimits(float metalIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int cap = int(metalIncome / 35.0f);

       Sea_IncomeLabLimits(metalIncome);
       Sea_IncomeBuilderLimits(metalIncome);

       //Always apply map limits, regardless of how eco changes labs limits
       dictionary mapLimits = Global::Map::Config.UnitLimits;
       UnitHelpers::ApplyUnitLimits(mapLimits);
    }

    void Sea_IncomeLabLimits(float metalIncome) {
        if (SeaLayout::Active()) {
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), Global::RoleSettings::Sea::MaxProductionYards + 1);
            return;
        }
        // One more advanced yard per 75 metal income. The first is always
        // allowed: its timing belongs to SeaEconomy's tech gate and save. A
        // cap of income/75 alone kept the legacy layout on T1 below 75 M/s,
        // i.e. for whole natural games (D-300).
        int seaLabCap = AiMax(1, int(metalIncome / 75.0f));

        // All three sides' T2 shipyards, legadvshipyard included (D-039).
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), seaLabCap);
    }

    void Sea_IncomeBuilderLimits(float metalIncome) {
        
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/

    IUnitTask@ Sea_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask) {
        float mi = aiEconomyMgr.metal.income;
        float ei = aiEconomyMgr.energy.income;
        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        // First, try to satisfy any SEA PRIMARY objectives (e.g., seaplane platform then tidal spam)
        IUnitTask@ objTask = Sea_TryHandleObjective(u, conLocation, unitSide, mi, ei);
        if (objTask !is null) return objTask;
        // The ladder itself is shared with every role that owns a construction
        // ship (helpers/sea_constructor_helpers.as, D-042), with SEA's numbers.
        SeaConstructor::Settings@ s = SeaConstructor::FromSea();
        if (u is Builder::primaryT1SeaConstructor) {
            IUnitTask@ t = SeaConstructor::T1Ladder(u, s, "SEA");
            if (t !is null) return t;
        } else {
            IUnitTask@ t = SeaConstructor::AssistPrimary(u, s, 160 * SECOND);
            if (t !is null) return t;
        }
        // Default fallback
        return defaultTask;
    }

    IUnitTask@ Sea_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask) {
        if (u is Builder::freelanceT2SeaConstructor) {
            // Freelance T2 sea constructors do default tasks for now
            return defaultTask;
        }
        if (u is Builder::primaryT2SeaConstructor) {
            SeaConstructor::Settings@ s = SeaConstructor::FromSea();
            IUnitTask@ t = SeaConstructor::T2Ladder(u, s, "SEA");
            if (t !is null) return t;
            @t = SeaConstructor::AssistPrimary(u, s, 120 * SECOND);
            if (t !is null) return t;
        }
        // Default fallback
        return defaultTask;
    }

    /******************************************************************************

    OBJECTIVE LOGIC

    ******************************************************************************/

    AIFloat3 Sea_GetObjectiveBuildPos(const Objectives::StrategicObjective@ o, const AIFloat3 &in fallback)
    {
        if (o is null) return fallback;
        if (o.pos.x != 0.0f || o.pos.z != 0.0f) return o.pos;
        if (o.line.length() > 0) return o.line[0];
        return fallback;
    }

    IUnitTask@ Sea_TryHandleObjective(CCircuitUnit@ builder, const AIFloat3 &in conLocation, const string &in unitSide, float mi, float ei)
    {
        // Find primary-group SEA objectives near base for T1 SEA constructors
        array<Objectives::StrategicObjective@> candidates = ObjectiveHelpers::Find(
            AiRole::SEA, unitSide, Objectives::ConstructorClass::SEA, 1, conLocation, ai.frame, Objectives::BuilderGroup::PRIMARY
        );
        if (candidates.length() == 0) return null;

        Objectives::StrategicObjective@ currentObjective = candidates[0];
        // Determine next step based on types present and eco
        bool wantsSeaplane = false;
        bool wantsTidal = false;
        for (uint i = 0; i < currentObjective.types.length(); ++i) {
            auto t = currentObjective.types[i];
            if (t == Objectives::BuildingType::SEAPLANE_FACTORY) wantsSeaplane = true;
            // Treat both explicit T1_TIDAL and legacy T1_ENERGY as tidal candidates
            if (t == Objectives::BuildingType::T1_TIDAL || t == Objectives::BuildingType::T1_ENERGY) wantsTidal = true;
        }

        string label = "PRIMARY";

        // If we've met end-state (platform at least queued once and energy threshold reached), mark complete
        if (wantsTidal) {
            float tidalTarget = Global::RoleSettings::Sea::TidalEnergyIncomeMinimum;
            bool platformSatisfied = !wantsSeaplane; // if not required, treat as satisfied
            if (wantsSeaplane) {
                string platNameCheck = UnitHelpers::GetSeaplanePlatformNameForSide(unitSide);
                platformSatisfied = (ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, platNameCheck) > 0);
            }
            if (platformSatisfied && ei >= tidalTarget) {
                ObjectiveHelpers::Complete(currentObjective.id);
                GenericHelpers::LogUtil("[SEA][" + label + "] Objective '" + currentObjective.id + "' complete: seaplane queued and energy >= " + tidalTarget, 2);
                return null;
            }
        }

        // If seaplane is desired and not yet queued for this objective, build one when metal income gate is met
        if (wantsSeaplane && mi >= 30.0f && (!Global::RoleSettings::Sea::SeaplanesAfterT2 || SeaFactories::T2Finished(unitSide))) {
            string platName = UnitHelpers::GetSeaplanePlatformNameForSide(unitSide);
            int alreadyQueued = ObjectiveHelpers::GetObjectiveBuildingsQueuedCount(currentObjective.id, platName);
            if (alreadyQueued <= 0) {
                // Attempt to assign and build platform
                if (!ObjectiveHelpers::TryAssign(currentObjective.id, "SEA_" + label)) return null;
                AIFloat3 pos = Sea_GetObjectiveBuildPos(currentObjective, Factory::GetPreferredFactoryPos());
                IUnitTask@ tFac = Global::RoleSettings::Sea::SeaplanesAfterT2 ? SeaBuild::Seaplane(builder)
                    : Builder::EnqueueSeaplanePlatform(unitSide, pos, SQUARE_SIZE * 24, 600 * SECOND);
                if (tFac is null) { ObjectiveHelpers::Unassign(currentObjective.id); return null; }
                ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, platName, 1);
                // Release assignment so follow-up stages (tidals) can proceed later
                ObjectiveHelpers::Unassign(currentObjective.id);
                GenericHelpers::LogUtil("[SEA][" + label + "] Enqueued seaplane platform '" + platName + "' for objective '" + currentObjective.id + "'", 2);
                return tFac;
            }
        }

        // After seaplane (or if not required), if energy below threshold and tidal desired, enqueue tidal
        if (wantsTidal && ei < Global::RoleSettings::Sea::TidalEnergyIncomeMinimum) {
            AIFloat3 pos2 = Sea_GetObjectiveBuildPos(currentObjective, conLocation);
            // Assign to avoid multiple builders colliding on the same tidal in one frame
            if (!ObjectiveHelpers::TryAssign(currentObjective.id, "SEA_" + label + "_TIDAL")) return null;
            IUnitTask@ tTidal = SeaLayout::Active()
                ? SeaLayout::Place(builder,ai.GetCircuitDef(UnitHelpers::GetTidalNameForSide(unitSide)),Task::BuildType::ENERGY,pos2)
                : Builder::EnqueueT1Tidal(unitSide, pos2, SQUARE_SIZE * 32, SECOND * 30, Task::Priority::NOW);
            if (tTidal !is null) {
                ObjectiveHelpers::IncrementDefenseQueued(currentObjective.id, UnitHelpers::GetTidalNameForSide(unitSide), 1);
                ObjectiveHelpers::Unassign(currentObjective.id);
                GenericHelpers::LogUtil("[SEA][" + label + "] Enqueued tidal for objective '" + currentObjective.id + "'", 2);
                return tTidal;
            }
            ObjectiveHelpers::Unassign(currentObjective.id);
        }

        return null;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Sea_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::SEA) match = true;
 
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] SEA", 2); 
        }

        return match;
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::SEA) !is null) return;
        RoleConfig@ cfg = RoleConfig(AiRole::SEA, cast<MainUpdateDelegate@>(@Sea_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Sea_Init);
        @cfg.LayoutPlanHandler = cast<LayoutPlanDelegate@>(@SeaLayout::Init);

        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Sea_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Sea_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Sea_MakeSwitchInterval);

        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Sea_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Sea_BuilderAiUnitRemoved);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Sea_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Sea_FactoryAiMakeTask);
        @cfg.MilitaryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@SeaCombat::MilitaryTask);
        @cfg.MilitaryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@SeaCombat::MilitaryRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Sea_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Sea_BuilderAiTaskRemoved);

        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Sea_SelectFactoryHandler);
        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Sea_EconomyUpdate);
       

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Sea_RoleMatch);
        
        RoleConfigs::Register(cfg);
    }
}
