#include "air_economy.as"
#include "air_waves.as"
#include "air_screen.as"
#include "air_raids.as"
#include "air_recon.as"
#include "air_base_response.as"
#include "air_naval_support.as"
#include "../../helpers/math/air_math.as"
namespace AirProduction {
    dictionary home; // mutually exclusive with AirWaves' held/launch ledgers
    int countLog = -100000;
    CRouteTask@ openingScout = null;
    int Projected(CCircuitDef@ d) { return d is null ? 0 : d.count + aiFactoryMgr.GetPendingRecruitCount(d); }
    float AvailableFighterValue()
    {
        return AirOperations::AvailableFighters(true);
    }
    IUnitTask@ Recruit(CCircuitUnit@ plant, const string &in name, int target, const string &in purpose, Task::Priority priority, bool utility = false)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !plant.circuitDef.CanBuild(d) || !d.IsAvailable(ai.frame) || Projected(d) >= target) return null;
        IUnitTask@ t = aiFactoryMgr.Enqueue(TaskS::Recruit(utility ? Task::RecruitType::BUILDPOWER : Task::RecruitType::FIREPOWER,
            priority, d, plant.GetPos(ai.frame), 64.0f));
        if (t !is null) {
            if (UnitHelpers::IsAirConstructor(d)) AirWorkforce::Admit(d, purpose == "constructor.expand");
            if (purpose == "opening.raid" && !AirMath::T1OpeningReady(AirEconomy::CompletedConstructors(),
                Global::RoleSettings::Air::OpeningAirConstructors, AirEconomy::OpeningNanoCompleted(), AirEconomy::OpeningNanoTarget(), AirEconomy::recovery))
                Invariants::Violation("INV-122", name, "T1 opening ordered before crew/support readiness");
            if (purpose == "wave.bomber" && !AirEconomy::MassBombers())
                Invariants::Violation("INV-102", name, "T2 bomber production below sustainable income gate");
            const string key = "air.crew.streak." + plant.id;
            aiTerrainMgr.SetLayoutInt(key, utility ? aiTerrainMgr.GetLayoutInt(key, 0) + 1 : 0);
            const string combatKey = "air.combat.streak." + plant.id;
            aiTerrainMgr.SetLayoutInt(combatKey, utility ? 0 : AiMin(
                Global::RoleSettings::Air::CombatOrdersPerEconomyConstructor,
                aiTerrainMgr.GetLayoutInt(combatKey, 0) + 1));
            if (!utility) aiTerrainMgr.SetLayoutInt("air.mix." + plant.id, (aiTerrainMgr.GetLayoutInt("air.mix." + plant.id, 0) + 1) % 10);
            GenericHelpers::LogUtil("[AIR][Produce] " + purpose + " " + name + " plant=" + plant.id + " projected=" + Projected(d) + "/" + target
                + " baseContact=" + AirBaseResponse::Emergency(), 1);
        }
        return t;
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        AirEconomy::Tick();
        if (Lifecycle::IsRetiring(u)) return aiFactoryMgr.Enqueue(TaskS::Wait(true, 3 * SECOND));
        const string name = u.circuitDef.GetName();
        const bool advanced = UnitHelpers::IsT2AircraftPlant(name);
        const bool basic = UnitHelpers::IsT1AircraftPlant(name);
        // Read the live bank at each completion: the one-second economy snapshot
        // can miss donations or depletion between several fast factory births.
        // Keep all existing unit-choice priorities; only discretionary holds
        // below may be bypassed. Native energy starvation still pauses work.
        const bool fundedProduction = advanced && Global::RoleSettings::Air::ContinuousFactoryProduction
            && aiEconomyMgr.metal.current > 0.0f;
        if (!advanced && !basic) {
            if (AirEcoLayout::Owns(u.GetPos(ai.frame))) {
                CCircuitUnit@ frame = AirBuild::FindAssistTarget(u, false, null, true);
                IUnitTask@ task = frame is null ? aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND))
                    : aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::HIGH, frame));
                AirWorkforce::Assign(u, task);
                return task;
            }
            IUnitTask@ amphib = AmphibiousOps::Produce(u, 200.0f);
            if (amphib !is null) return amphib;
            // A nano serves one bay even where reach discs overlap. Reacquire all IDs.
            int64 owner = -1;
            if (AirEconomy::nanoBay.get("" + u.id, owner) && owner >= 0 && owner < int(AirLayout::bays.length())) {
                CCircuitUnit@ plant = ai.GetTeamUnit(AirLayout::bays[int(owner)].factoryId);
                IBuilderTask@ job = plant is null ? null : cast<IBuilderTask>(plant.task);
                if (job !is null && job.target !is null && !Lifecycle::IsRetiring(plant))
                    return aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::NORMAL, job.target));
                CCircuitUnit@ frame = AirBuild::FindAssistTarget(u, false, null, true);
                if (frame !is null) return aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::HIGH, frame));
                return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
            }
            return AmphibiousOps::DefaultFactoryTask(u);
        }
        const string side = UnitHelpers::GetSideForUnitName(name);
        const string cons = advanced ? UnitHelpers::GetT2AirConstructorNameForSide(side) : UnitHelpers::GetT1AirConstructorNameForSide(side);
        IUnitTask@ t = null;
        if (basic && aiTerrainMgr.GetLayoutInt("air.scout.finished", 0) == 0) {
            const string scout = UnitHelpers::GetT1AirScoutForSide(side);
            array<Id>@ ids = ai.GetOwnedUnitIds();
            for (uint i = 0; i < ids.length(); ++i) {
                CCircuitUnit@ live = ai.GetTeamUnit(ids[i]);
                if (live !is null && live.circuitDef.GetName() == scout && live.GetBuildProgress() >= 1.0f)
                    aiTerrainMgr.SetLayoutInt("air.scout.finished", 1);
            }
            @t = Recruit(u, scout, 1, "opening.scout", Task::Priority::HIGH);
            if (t !is null) return t;
            if (aiTerrainMgr.GetLayoutInt("air.scout.finished", 0) == 0)
                return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        }
        const int firstCrew = basic ? Global::RoleSettings::Air::OpeningAirConstructors : (AirEconomy::PreparingFusion() ? 2 : 1);
        @t = Recruit(u, cons, firstCrew, "constructor.recovery", Task::Priority::HIGH, true);
        if (t !is null) return t;
        if (basic && !ProductionMath::CrewReady(AirEconomy::CompletedConstructors(), firstCrew))
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        const string fighter = AirEconomy::Fighter(advanced, side);
        // The first screen follows the completed crew without an income gate.
        // Recovery buildings use NOW priority; do not leave the plant empty
        // waiting for wind income while it could work on an interceptor.
        CCircuitUnit@ scoutUnit = ai.GetTeamUnit(aiTerrainMgr.GetLayoutInt("air.scout.id", -1));
        const int scoutAway = scoutUnit !is null && scoutUnit.circuitDef.GetName() == fighter ? 1 : 0;
        if (basic && aiTerrainMgr.GetLayoutInt("air.screen.established", 0) == 0) {
            const int initialTarget = ProductionMath::DefenceRecruitTarget(Global::RoleSettings::Air::HomeFighterFloor,
                AirScreen::CountOther(fighter), scoutAway);
            @t = Recruit(u, fighter, initialTarget, "opening.screen", Task::Priority::NORMAL);
            if (t !is null) return t;
            CCircuitDef@ initialFighter = ai.GetCircuitDef(fighter);
            if (initialFighter !is null && initialFighter.IsAvailable(ai.frame) && u.circuitDef.CanBuild(initialFighter)
                && Projected(initialFighter) < initialTarget)
                Invariants::Violation("INV-082", "" + u.id, "AIR failed to enqueue available initial fighter after completed crew");
            if (initialFighter !is null && Projected(initialFighter) >= initialTarget)
                aiTerrainMgr.SetLayoutInt("air.screen.established", 1);
        }
        const bool affordable = AirEconomy::energy >= 160.0f && (AirEconomy::bankE > 200.0f || !AirEconomy::recovery);
        const float intrusion = AirScreen::IntrusionCost();
        CCircuitDef@ fighterDef = ai.GetCircuitDef(fighter);
        float futureValue = 0.0f;
        if (fighterDef !is null) {
            futureValue = aiFactoryMgr.GetPendingRecruitCount(fighterDef) * fighterDef.costM;
            array<Id>@ owned = ai.GetOwnedUnitIds();
            for (uint i = 0; i < owned.length(); ++i) {
                CCircuitUnit@ unit = ai.GetTeamUnit(owned[i]);
                if (unit !is null && unit.circuitDef.GetName() == fighter && unit.GetBuildProgress() < 1.0f) futureValue += fighterDef.costM;
            }
        }
        // Fighters temporarily covering ground defense still fund the home
        // reserve. Counting only wall tasks requests endless replacements and
        // starves gunships/bombers despite an already funded free fighter pool.
        const float homeValue = AvailableFighterValue();
        const bool airEmergency = AirMath::Emergency(intrusion, homeValue, Global::RoleSettings::Air::InterceptCostRatio);
        const bool emergency = AirBaseResponse::Emergency() || airEmergency;
        CCircuitDef@ builder = ai.GetCircuitDef(cons);
        const int constructors = AirEconomy::ConstructorTarget(builder, advanced);
        const bool saving = AirEconomy::SavingForFirstLab();
        const bool openingReady = basic && AirRaids::OpeningPending() && AirMath::T1OpeningReady(AirEconomy::CompletedConstructors(),
            Global::RoleSettings::Air::OpeningAirConstructors, AirEconomy::OpeningNanoCompleted(), AirEconomy::OpeningNanoTarget(), AirEconomy::recovery);
        const string openingBomber = side == "cortex" ? "corshad" : side == "legion" ? "legmos" : "armthund";
        float producerPower = u.circuitDef.GetBuildSpeed();
        for (uint b = 0; b < AirLayout::bays.length() && b < AirEconomy::power.length(); ++b)
            if (AirLayout::bays[b].factoryId == u.id) producerPower = AiMax(producerPower, AirEconomy::power[b]);
        const bool workforceTurn = AirMath::WorkforceTurn(Projected(builder) < constructors,
            AirEconomy::FundConstructor(builder, producerPower), emergency,
            aiTerrainMgr.GetLayoutInt("air.combat.streak." + u.id, 0),
            Global::RoleSettings::Air::CombatOrdersPerEconomyConstructor);
        if (workforceTurn) {
            if (ProductionMath::ConstructorTurn(aiTerrainMgr.GetLayoutInt("air.crew.streak." + u.id, 0), Global::RoleSettings::Air::ConstructorsPerFighter)) {
                @t = Recruit(u, cons, constructors, "constructor.expand", Task::Priority::HIGH, true);
                if (t is null && builder !is null && builder.IsAvailable(ai.frame) && u.circuitDef.CanBuild(builder))
                    Invariants::Violation("INV-119", "" + u.id, "funded AIR workforce turn failed to recruit an available constructor");
            } else {
                @t = Recruit(u, fighter, Projected(fighterDef) + 1, "constructor.screen", Task::Priority::NORMAL);
            }
            if (t !is null) return t;
        }
        // Fighters covering this ground response are intentionally absent from
        // the home-wall ledger. Do not refill that floor ahead of gunships.
        if (!AirMath::Emergency(intrusion, homeValue, Global::RoleSettings::Air::InterceptCostRatio)) {
            @t = AirBaseResponse::Produce(u);
            if (t !is null) return t;
        }
        if (affordable) {
            const float cost = fighterDef is null ? 150.0f : fighterDef.costM;
            const float urgent = AiMax(float(Global::RoleSettings::Air::HomeFighterFloor) * cost,
                intrusion * Global::RoleSettings::Air::InterceptCostRatio);
            const int missing = AirMath::Missing(urgent, homeValue + futureValue, cost);
            @t = Recruit(u, fighter, Projected(fighterDef) + missing, "intercept", Task::Priority::HIGH);
            if (t !is null) return t;
        }
        @t = AirBaseResponse::Produce(u);
        if (t !is null) return t;
        if (!fundedProduction && (!affordable || AirEconomy::recovery)) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        @t = AirNavalSupport::Produce(u);
        if (t !is null) return t;
        if (openingReady) {
            const int goal = AirRaids::OpeningSize();
            aiTerrainMgr.SetLayoutInt("air.t1.openingReady", 1);
            if (side != "legion" || aiTerrainMgr.GetLayoutInt("air.t1.openingOrders", 0) < goal) {
                @t = Recruit(u, openingBomber, side == "legion" ? Projected(ai.GetCircuitDef(openingBomber)) + 1 : goal,
                    "opening.raid", Task::Priority::NORMAL);
                if (t !is null) {
                    const int orders = aiTerrainMgr.GetLayoutInt("air.t1.openingOrders", 0) + 1;
                    aiTerrainMgr.SetLayoutInt("air.t1.openingOrders", orders);
                    if (side == "legion" && orders >= goal) aiTerrainMgr.SetLayoutInt("air.t1.openingDone", 1);
                    return t;
                }
            }
        }
        if (basic && AirBuild::StarterReadyToRetire(u)) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));
        if (saving && !fundedProduction) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        // A lost scout gets another route. Utility never consumes a strike slot.
        if (basic && side != "legion" && ai.frame >= aiTerrainMgr.GetLayoutInt("air.scout.next", 0)) {
            @t = Recruit(u, UnitHelpers::GetT1AirScoutForSide(side), 1, "recon.replace", Task::Priority::NORMAL, true);
            if (t !is null) { aiTerrainMgr.SetLayoutInt("air.scout.next", ai.frame + Global::RoleSettings::Air::ScoutReplaceSeconds * SECOND); return t; }
        }
        // One completed advanced plant supplies the whole team's fighter/recon arm.
        if (advanced && u.id == AirRecon::FighterPlant()) {
            CCircuitDef@ radar = ai.GetCircuitDef(AirRecon::Name(side));
            if (radar !is null) {
                AirRecon::Unlock(radar);
                @t = Recruit(u, radar.GetName(), AirRecon::ProductionTarget(radar), "recon.wave", Task::Priority::NORMAL);
                if (t !is null) return t;
            }
            @t = Recruit(u, fighter, Projected(fighterDef) + 1, "dedicated.fighter", Task::Priority::NORMAL);
            if (t !is null) return t;
        }
        // Produce() above already funds the ground-defense deficit first.
        // A lingering contact must not veto replacement bomber production
        // once that reserve is funded. An air superiority emergency still can.
        const int strikeOrders = airEmergency ? 0 : AirMath::BomberOrders(homeValue, AirEconomy::EnemyAir(),
            AirEconomy::MassBombers() ? Global::RoleSettings::Air::MassBomberOrdersClear : Global::RoleSettings::Air::BomberOrdersClear,
            AirEconomy::MassBombers() ? Global::RoleSettings::Air::MassBomberOrdersParity : Global::RoleSettings::Air::BomberOrdersParity);
        const bool strike = strikeOrders > 0 && AirMath::BomberTurn(aiTerrainMgr.GetLayoutInt("air.mix." + u.id, 0), strikeOrders);
        if (basic && strike && !AirRaids::OpeningPending() && AirEconomy::metal >= 12.0f) {
            const string bomber = side == "cortex" ? "corshad" : side == "legion" ? "legmos" : "armthund";
            // Alternate finite land support and reusable T1 bomber groups.
            const int phase = aiTerrainMgr.GetLayoutInt("air.t1.mix", 0);
            {
                const bool supportFirst = phase % 2 == 0;
                for (int pass = 0; pass < 2; ++pass) {
                    const bool support = pass == 0 ? supportFirst : !supportFirst;
                    if (!support && AirEconomy::MassBombers() && side != "legion") continue;
                    if (support && aiBattle.EnemyCost(0) + aiBattle.EnemyCost(4) + aiBattle.EnemyCost(5) < 300.0f) continue;

                    int target = ProductionMath::StrikeTarget(AirEconomy::metal,
                        support ? Global::RoleSettings::Air::T1SupportMetalStep : Global::RoleSettings::Air::T1BomberMetalStep,
                        support ? 3 : Global::RoleSettings::Air::T1RaidMinimum, support ? (side == "cortex" ? Global::RoleSettings::Air::T1SupportCap : Global::RoleSettings::Air::T1StrikeOpenerSize) : Global::RoleSettings::Air::T1BomberCap);
                    // The cap is a reserve for the next raid. Committed
                    // survivors must not consume it indefinitely.
                    if (!support) target += AirOperations::BomberCount(bomber);
                    @t = Recruit(u, support ? RoleAir::GetT1StrikeAircraftNameForSide(side) : bomber, target,
                        support || side == "legion" ? "front.support" : "t1.bomber", Task::Priority::NORMAL);
                    if (t !is null) { aiTerrainMgr.SetLayoutInt("air.t1.mix", phase + 1); return t; }
                }
            }
        }
        if (advanced && strike && AirEconomy::MassBombers() && AirEconomy::metal >= 250.0f && aiBattle.EnemyCost(0) >= 1000.0f) {
            const string heavy = side == "cortex" ? "corcrwh" : side == "legion" ? "legfort" : "";
            @t = Recruit(u, heavy, 6, "heavy", Task::Priority::NORMAL);
            if (t !is null) return t;
        }
        if (advanced && strike && AirEconomy::MassBombers()) {
            const string bomber = UnitHelpers::GetT2WaveBomberForSide(side);
            CCircuitDef@ bd = ai.GetCircuitDef(bomber);
            CCircuitDef@ fd = ai.GetCircuitDef(fighter);
            // Native counts include frames and orders immediately, including births between slow ticks.
            const int b = AiMax(0, Projected(bd) - AirOperations::BomberCount(bomber));
            const int f = AiMax(0, Projected(fd) + AirScreen::CountOther(fighter) - int(AirOperations::escorts.getSize()));
            if (f < AirWaves::FightersFor(b)) {
                @t = Recruit(u, fighter, Projected(fd) + 1, "wave.escort", Task::Priority::NORMAL);
            } else if (b < AirWaves::ProductionTarget()) {
                @t = Recruit(u, bomber, Projected(bd) + 1, "wave.bomber", Task::Priority::NORMAL);
            }
            if (t !is null) return t;
        }
        // A sustainable production share leaves resources for growth. Emergency floor above bypasses this.
        if (!fundedProduction && AirEconomy::bankM < 80.0f && aiEconomyMgr.metal.pull > AirEconomy::metal * 1.2f)
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        // Keep the old lab available for economic crews and finite land support;
        // sustained advanced fighter production belongs to the advanced bays.
        if (basic && AirEconomy::t2 > 0 && AirEconomy::metal >= Global::RoleSettings::Air::TransitionMinMetal) {
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        }
        if (advanced && !fundedProduction && AirEconomy::TechGrowth() && !AirEconomy::MassBombers()
            && homeValue + futureValue >= AirEconomy::HomeValueTarget())
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        if (Global::RoleSettings::Air::UseDynamicFactoryProduction && (!advanced || AirEconomy::MassBombers())) {
            @t = FactoryProduction::MakeTask(u);
            if (t !is null) return t;
        }
        CCircuitDef@ fd = ai.GetCircuitDef(fighter);
        @t = Recruit(u, fighter, Projected(fd) + 1, "air.control", Task::Priority::NORMAL);
        if (fundedProduction && t is null && fd !is null && fd.IsAvailable(ai.frame) && u.circuitDef.CanBuild(fd))
            Invariants::Violation("INV-187", "" + u.id, "funded T2 AIR factory failed to queue its available fallback fighter");
        return t is null ? aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND)) : t;
    }
    void Reset() { home.deleteAll(); AirScreen::Reset(); countLog = -100000; }
    void Leave()
    {
        AirNavalSupport::Reset();
        AirBaseResponse::Reset();
        AirRecon::Reset();
        AirOperations::Reset();
        AirRaids::Reset();
        if (openingScout !is null && !openingScout.IsDead()) openingScout.Abort();
        @openingScout = null;
        array<IUnitTask@> holds;
        array<string>@ ids = home.getKeys();
        array<string>@ bombers = AirWaves::heldBombers.getKeys();
        array<string>@ escorts = AirWaves::heldFighters.getKeys();
        array<string>@ activeBombers = AirWaves::waveBombers.getKeys();
        array<string>@ activeFighters = AirWaves::waveFighters.getKeys();
        for (uint i = 0; i < activeBombers.length(); ++i) ids.insertLast(activeBombers[i]);
        for (uint i = 0; i < activeFighters.length(); ++i) ids.insertLast(activeFighters[i]);
        for (uint i = 0; i < bombers.length(); ++i) ids.insertLast(bombers[i]);
        for (uint i = 0; i < escorts.length(); ++i) ids.insertLast(escorts[i]);
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null) { u.SetFireState(u.circuitDef.GetFireState()); u.SetIdleMode(1); }
            if (u !is null && u.task !is null && holds.findByRef(u.task) < 0) holds.insertLast(u.task);
        }
        for (uint i = 0; i < holds.length(); ++i) holds[i].Abort();
        Reset(); AirWaves::Init();
    }
    IUnitTask@ HomeTask(CCircuitUnit@ u)
    {
        // This callback observes the finished scout before it can be lost on a sortie.
        if (AirEconomy::Active() && u !is null && u.GetBuildProgress() >= 1.0f
            && u.circuitDef.GetName() == UnitHelpers::GetT1AirScoutForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName()))) {
            if (aiTerrainMgr.GetLayoutInt("air.scout.id", -1) == -1) aiTerrainMgr.SetLayoutInt("air.scout.id", u.id);
            aiTerrainMgr.SetLayoutInt("air.scout.finished", 1);
            // Legion's Noctua is the roster's fighter/scout drone, without a
            // native SCOUT classification. Only the opening aircraft scouts.
            if (!AirScreen::IsFighter(u.circuitDef) || u.id == aiTerrainMgr.GetLayoutInt("air.scout.id", -1)) {
                if (openingScout !is null && !openingScout.IsDead()) return openingScout;
                @openingScout = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                if (openingScout !is null) {
                    array<AIFloat3> route;
                    array<AIFloat3> starts = Lanes::ScriptStarts(true);
                    if (starts.length() == 0) starts.insertLast(LayoutHelpers::TerrainCentre());
                    for (uint i = 0; i < starts.length(); ++i) route.insertLast(AirScreen::Clamp(starts[i]));
                    if (route.length() == 1) route.insertLast(AirScreen::Clamp(AIFloat3(route[0].x+512.0f,0,route[0].z+512.0f)));
                    openingScout.SetAirControl(true); openingScout.SetPatrol(true);
                    u.SetIdleMode(0); u.SetFireState(0);
                    openingScout.SetRoute(route);
                    GenericHelpers::LogUtil("[AIR][Scout] opening drone=" + u.id + " enemy starts=" + route.length(), 1);
                    return openingScout;
                }
            }
        }
        if (!AirEconomy::Active() || u is null || !AirScreen::IsFighter(u.circuitDef)) return null;
        const string key = "" + u.id;
        // Fighters already on a wave keep their assignment until it ends.
        if (AirWaves::heldFighters.exists(key) || AirWaves::waveFighters.exists(key) || AirWaves::launchQueue.exists(key)) return null;
        if (AirOperations::Committed(u.id)) return null;
        IUnitTask@ task = AirScreen::TaskFor(u);
        if (task !is null) home.set(key, true);
        return task;
    }
    void Removed(CCircuitUnit@ u)
    {
        if (u is null) return;
        AirRaids::Removed(u.id);
        home.delete("" + u.id); AirScreen::Removed(u.id);
        if (u.id == aiTerrainMgr.GetLayoutInt("air.scout.id", -1)) {
            aiTerrainMgr.SetLayoutInt("air.scout.id", -2); @openingScout = null;
        }
    }
    void Tick()
    {
        AirBaseResponse::Tick();
        AirRecon::Tick();
        AirNavalSupport::Tick();
        AirOperations::Tick();
        AirRaids::Update();
        AirScreen::Tick();
        array<Id>@ workers = ai.GetOwnedUnitIds();
        for (uint i = 0; i < workers.length(); ++i) {
            CCircuitUnit@ worker = ai.GetTeamUnit(workers[i]);
            IBuilderTask@ construction = worker is null ? null : cast<IBuilderTask>(worker.task);
            if (construction !is null && construction.GetBuildType() <= int(Task::BuildType::MEXUP)
                && construction.buildDef !is null && construction.target !is null
                && construction.target.GetBuildProgress() >= 1.0f)
                Invariants::Violation("INV-101", "" + construction.target.id, "AIR completed construction still owns workers");
        }
        // Noctua doubles as fighter and scout. Its global count cannot tell us
        // whether recon exists; lend one home aircraft after the replacement delay.
        if (Global::AISettings::Side == "legion" && aiTerrainMgr.GetLayoutInt("air.scout.id", -1) < 0
            && home.getSize() > uint(Global::RoleSettings::Air::HomeFighterFloor)
            && ai.frame >= aiTerrainMgr.GetLayoutInt("air.scout.next", 0)) {
            array<string>@ defenders = home.getKeys();
            for (uint i = 0; i < defenders.length(); ++i) {
                CCircuitUnit@ scout = ai.GetTeamUnit(parseInt(defenders[i]));
                if (scout is null || scout.circuitDef.GetName() != UnitHelpers::GetT1AirScoutForSide("legion")) continue;
                aiTerrainMgr.SetLayoutInt("air.scout.id", scout.id);
                aiTerrainMgr.SetLayoutInt("air.scout.next", ai.frame + Global::RoleSettings::Air::ScoutReplaceSeconds * SECOND);
                IUnitTask@ scouting = HomeTask(scout);
                if (scouting is null || !aiMilitaryMgr.TransferUnit(scout, scouting)) {
                    aiTerrainMgr.SetLayoutInt("air.scout.id", -2);
                    if (scouting !is null && !scouting.IsDead()) scouting.Abort();
                    @openingScout = null;
                    break;
                }
                // A wall task owns a whole cell. Transfer this drone only;
                // aborting the task would reassign all neighbouring fighters.
                home.delete(defenders[i]); AirScreen::Removed(scout.id);
                GenericHelpers::LogUtil("[AIR][Scout] replacement drone=" + scout.id, 1);
                break;
            }
        }
        array<string>@ staged = AirWaves::heldBombers.getKeys();
        for (uint i = 0; i < staged.length(); ++i) {
            CCircuitUnit@ unit = ai.GetTeamUnit(parseInt(staged[i]));
            IFighterTask@ task = unit is null ? null : cast<IFighterTask>(unit.task);
            if (task !is null && (task.GetFightType() == int(Task::FightType::DEFEND)
                || task.GetFightType() == int(Task::FightType::BOMB)))
                Invariants::Violation("INV-100", staged[i], "AIR held bomber belongs to an autonomous attack task");
        }
        // Static repairs have no timeout. Return borrowed economy assistance to
        // its production bay as soon as that plant has a unit frame again.
        array<string>@ nanos = AirEconomy::nanoBay.getKeys();
        for (uint i = 0; i < nanos.length(); ++i) {
            int64 owner = -1;
            if (!AirEconomy::nanoBay.get(nanos[i], owner) || owner < 0 || owner >= int(AirLayout::bays.length())) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(nanos[i]));
            IBuilderTask@ help = u is null ? null : cast<IBuilderTask>(u.task);
            if (help is null || help.GetBuildType() != int(Task::BuildType::REPAIR) || help.target is null || help.target.circuitDef.IsMobile()) continue;
            CCircuitUnit@ plant = ai.GetTeamUnit(AirLayout::bays[int(owner)].factoryId);
            IBuilderTask@ job = plant is null ? null : cast<IBuilderTask>(plant.task);
            if (job is null || job.target is null || Lifecycle::IsRetiring(plant)) continue;
            GenericHelpers::LogUtil("[AIR][Support] return to production bay=" + owner, 1);
            aiFactoryMgr.AbortTask(u.task);
        }
        array<string>@ ids = home.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            if (ai.GetTeamUnit(parseInt(ids[i])) is null || !AirScreen::routes.exists(ids[i])) home.delete(ids[i]);
            else if (AirWaves::heldFighters.exists(ids[i]) || AirWaves::waveFighters.exists(ids[i]))
                Invariants::Violation("INV-072", ids[i], "AIR fighter has both home and wave assignment");
        }
        if (ai.frame - countLog >= 30 * SECOND) {
            countLog = ai.frame;
            GenericHelpers::LogUtil("[AIR][Attack] home=" + home.getSize() + " target=" + AirEconomy::HomeTarget()
                + " heldBombers=" + AirWaves::heldBombers.getSize() + " escorts=" + AirWaves::heldFighters.getSize()
                + " wave=" + AirWaves::waveIndex + " enemyAir=" + int(AirEconomy::EnemyAir()), 1);
        }
    }
}
