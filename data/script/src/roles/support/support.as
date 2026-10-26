// role: SUPPORT
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../helpers/construction/economy_helpers.as"
#include "../../helpers/construction/guard_helpers.as"
#include "../../helpers/combat/porc_helpers.as"
#include "../../types/role_config.as"
#include "../../global.as"
#include "../../types/terrain.as"
#include "../../helpers/objectives/objective_helpers.as"
#include "support_build.as"

namespace RoleSupport {

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/

    void Support_Init() {
        GenericHelpers::LogUtil("Support role initialization logic executed", 2);

        // Apply SUPPORT role settings (formerly FrontTech)
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Support::AllyRange);
        // Change scout cap (unit count)
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Support::MilitaryScoutCap;

        // Change attack gate (power threshold, not a headcount)
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Support::MilitaryAttackThreshold;

        // Change raid thresholds (power)
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Support::MilitaryRaidMinPower; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Support::MilitaryRaidAvgPower; 

        Support_ApplyStartLimits();
        SupportProduction::Init();
        if (Global::RoleSettings::Support::ExperimentalBuild) SupportBuild::Init();

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::SUPPORT, "SUPPORT");
    }

    void Support_ApplyStartLimits() {
        dictionary startLimits; 

        startLimits.set("armap", 0);
        startLimits.set("corap", 0);
        startLimits.set("legap", 0);

        startLimits.set("armsilo", 0);
        startLimits.set("corsilo", 0);
        startLimits.set("legsilo", 0);
        
        startLimits.set("armrectr", 5);
        startLimits.set("cornecro", 5);

        RoleLimitHelpers::DisableT1Combat(startLimits, Global::AISettings::Side);

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Support start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    void Support_MainUpdate() {
        //LogUtil("Support update logic executed", 5);
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Support_EconomyUpdate() {
        // Apply income-based unit caps similar to TECH
        float metalIncome = aiEconomyMgr.metal.income;
        Support_IncomeBuilderLimits(metalIncome);
        if (Global::RoleSettings::Support::ExperimentalBuild) SupportBuild::Tick();
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    string Support_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if (isStart) {
            if (Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Support_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
        }

        return "";
    } 

    // Factory unit lifecycle hooks (Support role)
    void Support_FactoryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) {
            GenericHelpers::LogUtil("[SUPPORT] FactoryAiUnitAdded: unit=<null>", 2);
            return;
        }

        if (usage != Unit::UseAs::FACTORY)
            return;

        const CCircuitDef@ facDef = unit.circuitDef;
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) {
            array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
            for (uint i = 0; i < spam.length(); ++i)
                ai.GetCircuitDef(spam[i]).SetIgnore(true);
        }

        GenericHelpers::LogUtil("[SUPPORT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage, 3);
    }

    void Support_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        Lifecycle::Forget(unit);
        //GenericHelpers::LogUtil("[SUPPORT] FactoryAiUnitRemoved id=" + (unit is null ? -1 : unit.id) + " usage=" + usage, 3);
        // Factory manager handles primary/anchor references; Lifecycle above
        // retains the disappearance time of SUPPORT's reclaimed opening lab.
    }

    bool Support_AiIsSwitchTime(int lastSwitchFrame) {
        int interval = (30 * SECOND);
        return (lastSwitchFrame + interval) <= ai.frame;
    }

    bool Support_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        const bool isOK = (armyCost > 0.4f * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        assistRequired = !isOK;
        return isOK;
    }

    int Support_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Front::MinAiSwitchTime, Global::RoleSettings::Front::MaxAiSwitchTime) * SECOND;
    }

    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    IUnitTask@ Support_BuilderAiMakeTask(CCircuitUnit@ u) {
        if (Global::RoleSettings::Support::ExperimentalBuild) return SupportBuild::MakeTask(u);
        GenericHelpers::LogUtil("[Support_BuilderAiMakeTask] called for builder", 3);
        if (u is null) return null; // Defensive; expected non-null

        // Pre-create and cache a default task instance; never recreate inside this function.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(u.id, "SUPPORT");

        const CCircuitDef@ udef = u.circuitDef;
        if (udef is null) return defaultTask;

        // If the default task is a BUILDER and its build type is MEX/MEXUP/GEO/GEOUP, don't override it; return immediately.
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
            return Support_Commander_AiMakeTask(u, defaultTask);
        }

        // Route T1 bot constructors to Support logic; others may guard or fall back
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            if (u is Builder::primaryT1BotConstructor || u is Builder::secondaryT1BotConstructor) {
                return Support_T1Constructor_AiMakeTask(u, defaultTask);
            } else {
                string key = "" + u.id;
                CCircuitUnit@ tmp = null;
                if (Builder::primaryT1BotConstructor !is null
                    && Builder::primaryT1BotConstructor.id != u.id
                    && Builder::primaryT1BotConstructorGuards.get(key, @tmp)) {
                    return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT1BotConstructor, Task::Priority::HIGH, true, 200 * SECOND);
                }
                @tmp = null;
                if (Builder::secondaryT1BotConstructor !is null
                    && Builder::secondaryT1BotConstructor.id != u.id
                    && Builder::secondaryT1BotConstructorGuards.get(key, @tmp)) {
                    return GuardHelpers::AssignWorkerGuard(u, Builder::secondaryT1BotConstructor, Task::Priority::HIGH, true, 200 * SECOND);
                }
            }
        }
        // Fallback to cached default task
        return defaultTask;
    }

    /******************************************************************************

    BUILDER LOGIC (COMMANDER)

    ******************************************************************************/ 

    // For the early game window, keep the commander assigned to guard
    // the primary T1 bot lab or T1 vehicle plant (if present).
    IUnitTask@ Support_Commander_AiMakeTask(CCircuitUnit@ comm, IUnitTask@ defaultTask)
    {
        if (comm is null) return defaultTask;

        // Configurable deadline (in frames) after which the commander stops
        // prioritizing factory assist and falls back to default behavior.
        const int SUPPORT_FACTORY_ASSIST_DEADLINE_FRAMES = Global::RoleSettings::Support::CommanderFactoryAssistDeadlineSeconds * SECOND;
        if (ai.frame > SUPPORT_FACTORY_ASSIST_DEADLINE_FRAMES) {
            // After the early window, fall back to default behavior
            return defaultTask;
        }

        // Prefer guarding the primary T1 bot lab first, then T1 vehicle plant if available.
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

        // Assign a high-priority guard task so the commander sticks near the frontline factory.
        // The guard timeout is configurable via role settings.
        const int SUPPORT_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES = Global::RoleSettings::Support::CommanderFactoryAssistGuardTimeoutSeconds * SECOND;
        IUnitTask@ guardTask = GuardHelpers::AssignWorkerGuard(
            comm,
            target,
            Task::Priority::HIGH,
            true,
            SUPPORT_FACTORY_ASSIST_GUARD_TIMEOUT_FRAMES // guard duration; can be renewed while within deadline
        );

        return (guardTask !is null ? guardTask : defaultTask);
    }

    CCircuitUnit@ energizer1 = null;
    CCircuitUnit@ energizer2 = null;

    void Support_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		//LogUtil("BUILDER::AiUnitAdded:" + unit.circuitDef, 2);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

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

    void Support_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (energizer1 is unit)
			@energizer1 = null;
		else if (energizer2 is unit)
			@energizer2 = null;
	}

    void Support_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Support_BuilderAiTaskAdded] called for task", 3);
    }

    void Support_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {

    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/ 

    IUnitTask@ Support_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask) {
        // Econ snapshot
        float mi = aiEconomyMgr.metal.income;
        float ei = aiEconomyMgr.energy.income;
        bool stall = aiEconomyMgr.isEnergyStalling;
        bool isEnergyFull = aiEconomyMgr.isEnergyFull;

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Primary constructor branch
        if (u is Builder::primaryT1BotConstructor) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

            // Try T2 lab if eco allows
            bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLab(
                /*mi*/ mi,
                /*ei*/ ei,
                /*metalCurrent*/ aiEconomyMgr.metal.current,
                /*requiredMetalIncome*/ Global::RoleSettings::Support::MinimumMetalIncomeForT2Lab,
                /*requiredMetalCurrent*/ Global::RoleSettings::Support::RequiredMetalCurrentForT2Lab,
                /*requiredEnergyIncome*/ Global::RoleSettings::Support::MinimumEnergyIncomeForT2Lab,
                /*constructorDef*/ u.circuitDef,
                /*t2BotLabCount*/ t2LabCount,
                /*maxAllowed*/ Global::RoleSettings::Support::MaxT2BotLabs,
                /*hasPrimaryFactory*/ (Factory::primaryT1BotLab !is null)
            );
            if (shouldT2Lab) {
                IUnitTask@ tLab = Builder::EnqueueT2BotLabIfNeeded(unitSide, Factory::GetT2BotLabPos(), SQUARE_SIZE * 20, SECOND * 300);
                if (tLab !is null) return tLab;
            }

            // A mex upgrade outranks the whole energy ladder: best metal per metal,
            // and the supply of spots is finite. See doc/known-issues.md KI-213.
            if (Global::RoleSettings::MexUpgradeFirst)
            {
            	IUnitTask@ tMexUp = EconomyHelpers::EnqueueMexUpgradeIfFirst(u, Global::Map::StartPos,
            			Global::RoleSettings::MexUpgradeRadius,
            			Global::RoleSettings::MexUpgradeMaxConcurrent, "SUPPORT");
            	if (tMexUp !is null) return tMexUp;
            }

            // Energy converter via shared economy helper with Support thresholds
            if (EconomyHelpers::ShouldBuildT1EnergyConverter(
                /*metalIncome*/ mi,
                /*energyIncome*/ ei,
                /*energyCurrent*/ aiEconomyMgr.energy.current,
                /*energyStorage*/ aiEconomyMgr.energy.storage,
                /*untilMetalIncome*/ Global::RoleSettings::Support::BuildT1ConvertersUntilMetalIncome,
                /*minEnergyIncome*/ Global::RoleSettings::Support::BuildT1ConvertersMinimumEnergyIncome,
                /*minEnergyCurrentPercent*/ Global::RoleSettings::Support::BuildT1ConvertersMinimumEnergyCurrentPercent
            )) {
                IUnitTask@ tConv = Builder::EnqueueT1EnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tConv !is null) return tConv;
            }

            // Basic solar
            if (EconomyHelpers::ShouldBuildT1Solar(
                /*energyIncome*/ ei,
                /*minEnergyIncome*/ Global::RoleSettings::Support::SolarEnergyIncomeMinimum
            )) {
                IUnitTask@ tSolar = Builder::EnqueueT1Solar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tSolar !is null) return tSolar;
            }

            // Build a T1 nano caretaker if income-based target or reserves-based condition is met
            float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
                : 0.0f;
            // Only build nanos if we have a preferred factory to anchor around
            if (Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(
                ei,
                mi,
                Global::RoleSettings::Support::NanoEnergyPerUnit,
                Global::RoleSettings::Support::NanoMetalPerUnit,
                Global::RoleSettings::Support::NanoMaxCount,
                aiEconomyMgr.metal.current,
                Global::RoleSettings::Support::NanoBuildWhenOverMetal,
                energyPercent
            )) {
                // Centralized selection with per-factory nano caps and prioritization
                CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                if (targetFactory !is null) {
                    IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::NORMAL);
                    if (tNano !is null) return tNano;
                }
            }

            // Advanced solar with Support thresholds and T2 gating (unified helper)
            if (EconomyHelpers::ShouldBuildT1AdvancedSolar(
                /*energyIncome*/ ei,
                /*metalIncome*/ mi,
                /*energyIncomeMinimumThreshold*/ Global::RoleSettings::Support::AdvancedSolarEnergyIncomeMinimum,
                /*energyIncomeMaximumThreshold*/ Global::RoleSettings::Support::AdvancedSolarEnergyIncomeMaximum,
                /*t2ConstructorCount*/ t2ConstructionBotCount,
                /*t2FactoryCount*/ t2LabCount,
                /*isT2FactoryQueued*/ Factory::IsT2LabBuildQueued(),
                /*enableT2ProgressGate*/ true,
                /*metalIncomeFallbackMinimum*/ 6.0f
            )) {
                IUnitTask@ tAdvSolar = Builder::EnqueueT1AdvancedSolar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tAdvSolar !is null) return tAdvSolar;
            }

            // If a T2 constructor exists, assist it briefly
            if (Builder::primaryT2BotConstructor !is null) {
                return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT2BotConstructor, Task::Priority::HIGH, true, 120 * SECOND);
            }
        }
        else if (u is Builder::secondaryT1BotConstructor) {
            // Optional: specialize recycle here if desired, currently no-op
            if (EconomyHelpers::ShouldSecondaryT1AssistPrimary(
                /*metalIncome*/ mi,
                /*threshold*/ Global::RoleSettings::Support::SecondaryT1AssistMetalIncomeMax
            )) {
                return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT1BotConstructor, Task::Priority::HIGH, true, 20 * SECOND);
            }
        }

        return defaultTask;
    }

    /******************************************************************************

    ECONOMY LOGIC

    ******************************************************************************/ 

    void Support_IncomeBuilderLimits(float metalIncome) {
        // Determine and apply caps for T1/T2 land builders based on economy, honoring Support hard caps
        string side = Global::AISettings::Side;

        // T1 builder cap via economic helper; honor min and global max
        int t1BuilderCap = EconomyHelpers::CalculateT1BuilderCap(
            /*metalIncome*/ metalIncome,
            /*minCap*/ 5,
            /*maxCap*/ Global::RoleSettings::Support::MaxT1Builders
        );
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetT1LandBuilders(side), t1BuilderCap);

        // T2 builder cap via economic helper; honor min and global max
        int t2BuilderCap = EconomyHelpers::CalculateT2BuilderCap(
            /*metalIncome*/ metalIncome,
            /*minCap*/ 3,
            /*maxCap*/ Global::RoleSettings::Support::MaxT2Builders
        );
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetT2LandBuilders(side), t2BuilderCap);

        // Re-apply merged map+role unit limits so map constraints always prevail
        if (Global::Map::MergedUnitLimits.getKeys().length() > 0) {
            GenericHelpers::LogUtil("[SUPPORT][Limits] Re-applying merged map+role unit limits (economy update)", 4);
            UnitHelpers::ApplyUnitLimits(Global::Map::MergedUnitLimits);
        }
        // A map may tighten these caps but must not reopen decoy spam.
        SupportProduction::ApplyLimits();
        SupportProduction::VerifyLimits();
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Support_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::SUPPORT) match = true;

        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] SUPPORT", 2); 
        }
  
        return match;
    }

    /******************************************************************************

    PORCUPINE CHAIN

    ******************************************************************************/

    // SUPPORT trades its Juno for the side's ranged tactical launcher.
    //
    // Why the swap is the whole fix. CMilitaryManager::DefaultMakeDefence walks
    // the chain accumulating cost and stops once the running total passes
    // maxCost = amountFactor (32-48) x metal income. The launchers sit at chain
    // positions 16 and 25, behind a cumulative ~24k and ~48k of metal - an
    // income in the hundreds - so no cluster ever reaches them and the class is
    // never built. The Juno at position 7 sits behind ~2.5k, which a real
    // cluster does reach. Putting the launcher there is not a preference over
    // the Juno so much as the only slot where the launcher can exist.
    //
    // Why SUPPORT and not everyone. SUPPORT is the defensive economic role: it
    // disables its own T1 combat production and expects allies to fight, so a
    // stockpiled ranged strike it can fire from behind its own porc is worth
    // more to it than to a role that closes distance. The Juno answers radar,
    // jammers, mines and scout spam, all of which a forward ally is better
    // placed to handle; giving that up is the trade the role wants.
    //
    // Both are T2, and DefaultMakeDefence skips an unavailable def before it
    // adds its cost, so the swap is inert until an advanced constructor exists
    // and the early chain is untouched. After that the point costs the
    // difference - +960 Armada, +540 Cortex, +590 Legion - which pushes the
    // entries behind it slightly further out of budget. That is the accepted
    // cost of the trade.
    void Support_PorcChain(const string &in side)
    {
        array<string>@ land = PorcHelpers::DefaultChain(side, false);
        const string juno = PorcHelpers::ForSide(@PorcHelpers::Junos, side);
        const string launcher = PorcHelpers::ForSide(@PorcHelpers::TacticalLaunchers, side);

        if (juno.length() == 0 || launcher.length() == 0) {
            // An unrecognised side, or one of the tables missing an entry.
            // Keep the default rather than silently building nothing.
            GenericHelpers::LogUtil("[Porc] SUPPORT: no launcher mapping for side " + side
                + "; keeping the default chain", 2);
        } else {
            const uint swapped = PorcHelpers::Replace(@land, juno, launcher);
            if (swapped > 0) {
                GenericHelpers::LogUtil("[Porc] SUPPORT: " + side + " swapped " + swapped
                    + " x " + juno + " -> " + launcher, 1);
            } else {
                // The chain no longer holds the Juno - a config edit, or a mod
                // option that rewrote it. Append rather than lose the launcher
                // entirely; last is where it already was, so this is no worse
                // than the default.
                if (!PorcHelpers::Contains(land, launcher)) {
                    land.insertLast(launcher);
                }
                GenericHelpers::LogUtil("[Porc] SUPPORT: " + side + " has no " + juno
                    + " in the chain; appended " + launcher, 2);
            }
        }
        aiMilitaryMgr.SetPorcChain(side, false, land);
        // Native anchor AND final-site checks enforce the own-base restriction.
        // Classification follows the effective T1 constructor build menu,
        // including faction/content variants, rather than guessing from names.
        array<string> builders = UnitHelpers::GetAllT1BotConstructors();
        array<string> vehicles = UnitHelpers::GetAllT1VehicleConstructors();
        array<string> ships = UnitHelpers::GetAllT1SeaConstructors();
        array<string> aircraft = UnitHelpers::GetAllT1AirConstructors();
        for (uint index = 0; index < vehicles.length(); ++index) builders.insertLast(vehicles[index]);
        for (uint index = 0; index < ships.length(); ++index) builders.insertLast(ships[index]);
        for (uint index = 0; index < aircraft.length(); ++index) builders.insertLast(aircraft[index]);
        array<string>@ water = PorcHelpers::DefaultChain(side, true);
        array<string> restricted = land;
        for (uint index = 0; index < water.length(); ++index) restricted.insertLast(water[index]);
        for (uint index = 0; index < restricted.length(); ++index) {
            CCircuitDef@ definition = ai.GetCircuitDef(restricted[index]);
            // Sensor and wall utility remains available outside the home base.
            if (definition is null || definition.GetMaxRange() <= 0.0f) continue;
            for (uint builderIndex = 0; builderIndex < builders.length(); ++builderIndex) {
                CCircuitDef@ builder = ai.GetCircuitDef(builders[builderIndex]);
                if (builder !is null && builder.CanBuild(definition)) {
                    aiBuilderMgr.SetBuildRadius(definition, Global::Map::StartPos, Global::RoleSettings::Support::HomeDefenceRadius);
                    break;
                }
            }
        }

        aiMilitaryMgr.SetPorcChain(side, true, water);
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::SUPPORT) !is null) return;
        RoleConfig@ cfg = RoleConfig(AiRole::SUPPORT, cast<MainUpdateDelegate@>(@Support_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Support_Init);

        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Support_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Support_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Support_MakeSwitchInterval);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Support_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@SupportBuild::FactoryTask);

        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Support_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Support_BuilderAiUnitRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Support_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Support_BuilderAiTaskRemoved);

        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Support_SelectFactoryHandler);
        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Support_EconomyUpdate);
        @cfg.FactoryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Support_FactoryAiUnitAdded);
        @cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Support_FactoryAiUnitRemoved);
            

        @cfg.PorcChainHandler = cast<PorcChainDelegate@>(@Support_PorcChain);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Support_RoleMatch);

        RoleConfigs::Register(cfg);
    }
}
