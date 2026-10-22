// Deterministic economy build order for TECH (D-058, D-063). Formula: doc/eco-planner.md.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../manager/builder.as"
#include "layout.as"
#include "../../manager/economy.as"
#include "../../helpers/math/build_power_math.as"
#include "../../helpers/math/tech_economy_math.as"

/******************************************************************************

ECO PLANNER

A pure function of the economy's state that names the next economy structure
to build, re-evaluated every time a constructor asks for work, so the build
order re-adjusts as the game goes. The state: the map's wind range and
current wind, its tidal strength, energy and metal income, energy and metal
banked against storage, what stands (solars, advanced solars, winds, fusions,
converters, storages, turrets), the build power standing around the base,
whether a T2 lab and T2 constructors exist, what the asking constructor can
build, and what the turret box has room for (D-063).

The order it produces, from the meta (doc/eco-planner.md for the numbers):

  0. The opening (roles/tech.as Opening) claims every reachable mex within
     OpeningMexRadius before this planner runs; nothing pays back faster.
  1. Energy draining (bank under EcoEnergyLowPercent and pull over income):
     the source with the lowest metal per E/s the constructor can build,
     the bank can pay within EcoAffordSeconds, and the box can hold.
  2. The advanced lab the moment its income gate passes: it unlocks the
     T2 constructors that upgrade mexes and build advanced converters; and
     a T2 builder's first job is the nearest owned mex not yet upgraded
     (MexUpgradeRadius, MexUpgradeMaxConcurrent at a time).
  3. Energy floating (bank near full) or a surplus twice a converter's draw:
     a converter; advanced when a T2 constructor asks. Energy under
     construction does not block it - the surplus is measured.
  4. Metal floating, or build power short of EcoBuildPowerPerMetal times
     the metal income: a construction turret on the next planned slot,
     nearest the factories first.
  5. Energy below the target for this metal income and not floating: the
     cheapest source as in 1. One energy structure at a time (D-037).
  6. Storage: one energy storage once winds carry the base or the bank is
     under EcoStorageSeconds of income; metal storage when metal is full.
  7. Metal floating with energy already ahead: the best-payback source
     anyway, unless energy is already twice the target.
  8. Otherwise nothing: the ladder's factories, defence and military run.

  Scaling, in one line: metal from mexes (opening, expansion, T2 upgrades)
  and from converters fed by measured energy surplus; energy by cheapest
  metal per E/s up to a target that ramps with metal income; build power
  from static turrets against a per-metal target; the T2 lab as soon as
  income clears its gate, because everything above it needs T2 builders.

Range is part of every choice: an option the turret box cannot hold within
a turret's reach is not offered, and what is chosen is pinned to the box
cells nearest a turret (Layout::Place). Nothing here spirals.

TECH uses the default context (Tech::EcoPlannerEnabled). Experimental AIR
opts into an AIR context after sustained +50 metal, sharing the chooser while
keeping AIR reservations, execution, milestones and aircraft demand separate.

******************************************************************************/
namespace EcoPlanner {
    string ConversionReasonName(ConversionReason reason) {
        if (reason == READY) return "ready";
        if (reason == PENDING) return "pending";
        if (reason == CAPACITY) return "capacity";
        if (reason == METAL_FULL) return "metal-full";
        if (reason == UNAVAILABLE) return "unavailable";
        if (reason == UNBUILDABLE) return "unbuildable";
        if (reason == INCOME) return "income";
        if (reason == PLACEMENT) return "placement";
        return "no-option";
    }
    class ConversionDecision {
        CCircuitUnit@ worker;
        bool read = false;
        float headroom = 0.0f;
        bool placementRejected = false;
        int placementRejectedDef = -1;
        bool selectionRejected = false;
        void Reset(CCircuitUnit@ unit) {
            @worker = unit; read = false; headroom = 0.0f;
            placementRejected = false; placementRejectedDef = -1; selectionRejected = false;
        }
    }
    // Callback-local contents, reused storage. Allocate only at a new nesting
    // high-water mark, not per builder ask (16 AIs / late armies). Release drops
    // the unit handle and restores the caller; enqueue invalidates headroom.
    // HeavyStrategyProbe verifies nested restoration and storage reuse.
    ConversionDecision@ conversionDecision;
    array<ConversionDecision@> conversionWorkspaces;
    uint conversionDepth = 0;
    void BeginConversionDecision(CCircuitUnit@ worker) {
        if (conversionDepth == conversionWorkspaces.length())
            conversionWorkspaces.insertLast(ConversionDecision());
        @conversionDecision = conversionWorkspaces[conversionDepth++];
        conversionDecision.Reset(worker);
    }
    void EndConversionDecision(ConversionDecision@ previous) {
        conversionDecision.Reset(null);
        --conversionDepth;
        @conversionDecision = previous;
    }
    float ConversionSupply() {
        if (conversionDecision is null) return TechConversionHeadroom();
        if (!conversionDecision.read) {
            conversionDecision.headroom = TechConversionHeadroom();
            conversionDecision.read = true;
        }
        return conversionDecision.headroom;
    }
    bool FundedConverterRecovery(CCircuitDef@ def, int pending) {
        return Global::RoleSettings::Tech::EconomyRecoveryEnabled && def !is null
            && ReplacementFunded(aiTerrainMgr.GetLostReservationCount(def), pending,
                aiEconomyMgr.metal.current, def.costM);
    }
    ConversionReason TechConversionAdmission(CCircuitDef@ def, CCircuitUnit@ worker) {
        if (TechBuild::MetalFullLong() || aiEconomyMgr.isMetalFull) return METAL_FULL;
        if (def is null) return UNAVAILABLE;
        const int pending = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::CONVERT), def)
            + aiBuilderMgr.GetUnfinishedCount(def);
        const int parallel = TechChain::EnergyBankFloats() ? Global::RoleSettings::Tech::ConverterParallel : 1;
        const float income = Economy::GetMinMetalIncomeLast10s();
        const bool advanced = def.GetName() == UnitHelpers::GetAdvEnergyConverterNameForSide(Global::AISettings::Side);
        const ConversionReason reason = DecideConversion(false, true, pending, parallel,
            ConversionSupply() >= aiEconomyMgr.GetEnergyUse(def), def.IsAvailable(ai.frame),
            worker is null || (worker.circuitDef !is null && worker.circuitDef.CanBuild(def)),
            advanced ? (income >= Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter || FundedConverterRecovery(def, pending))
                : income < Global::RoleSettings::Tech::BuildT1ConvertersUntilMetalIncome,
            conversionDecision !is null && conversionDecision.placementRejected
                && conversionDecision.placementRejectedDef == def.id);
        return reason == READY && conversionDecision !is null && conversionDecision.selectionRejected
            ? (pending > 0 ? PENDING : NO_OPTION) : reason;
    }
    bool TechConversionCanDefer() {
        CCircuitUnit@ worker = conversionDecision is null ? null : conversionDecision.worker;
        const bool advanced = worker is null ? TechBuild::IntoT2()
            : UnitHelpers::GetConstructorTier(worker.circuitDef) >= 2;
        const string side = Global::AISettings::Side;
        if (advanced) {
            const ConversionReason advancedReason = TechConversionAdmission(
                ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(side)), worker);
            if (advancedReason == READY || advancedReason == PENDING) return true;
        }
        const ConversionReason reason = TechConversionAdmission(
            ai.GetCircuitDef(UnitHelpers::GetEnergyConverterNameForSide(side)), worker);
        return reason == READY || reason == PENDING;
    }
    // At most one entry per live worker; destruction removes it. Emit only
    // reason/phase transitions, not changing bank values on every decision.
    dictionary conversionReasons;
    void TraceConversion(CCircuitUnit@ worker, ConversionReason reason) {
        if (worker is null) return;
        const string key = "" + worker.id;
        const string signature = "" + int(reason) + ":" + TechPlan::phase;
        string previous;
        if (conversionReasons.get(key, previous) && previous == signature) return;
        conversionReasons.set(key, signature);
        GenericHelpers::LogUtil("[TECH][Conversion] worker=" + worker.id + " phase=" + TechPlan::phase
            + " reason=" + ConversionReasonName(reason) + " headroom=" + int(ConversionSupply())
            + " energy=" + int(aiEconomyMgr.energy.income) + " metal=" + int(aiEconomyMgr.metal.current), 1);
    }
    array<string> techConverterNames;
    float TechConversionHeadroom() {
        if (AiPerfEnabled) AiPerfBeginLabel("tech-conversion-capacity");
        // Fixed roster, initialized once per script instance. Read live counts
        // on every admission: same-frame enqueues/transfers must be visible.
        // No owned-unit scan or stale per-frame capacity cache. Native queued
        // counts exclude frames (already in def.count): O(D * P), D <= 12
        // definitions and P pending tasks. Called by builder decisions only.
        if (techConverterNames.length()==0) {
            const array<string> sides={"armada","cortex","legion"};
            for (uint index=0;index<sides.length();++index) {
                techConverterNames.insertLast(UnitHelpers::GetEnergyConverterNameForSide(sides[index]));
                techConverterNames.insertLast(UnitHelpers::GetAdvEnergyConverterNameForSide(sides[index]));
                techConverterNames.insertLast(UnitHelpers::GetNavalEnergyConverterNameForSide(sides[index]));
                techConverterNames.insertLast(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(sides[index]));
            }
        }
        float capacity=0;
        for (uint index=0;index<techConverterNames.length();++index) {
            CCircuitDef@ definition=ai.GetCircuitDef(techConverterNames[index]);
            if (definition is null) continue;
            capacity+=aiEconomyMgr.GetEnergyUse(definition)*(definition.count
                +aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::CONVERT),definition));
        }
        const float headroom = BuildPowerMath::ConversionHeadroom(aiEconomyMgr.energy.income,
            TeamEconomy::OwnEnergy(TeamEconomy::USAGE),ai.GetTeamRulesParam("mmUse",0.0f),
            capacity,Global::RoleSettings::Tech::EcoEnergyReserve);
        if (AiPerfEnabled) AiPerfEndLabel();
        return headroom;
    }

    class State {
        bool air = false; // default preserves TECH policy and geometry
        bool allowConverters = true; // caller may reserve surplus metal for production/build power
        bool allowReactors = true; // role-local home upgrades may precede reactors
        float energyGoal = 0.0f; // optional role objective floor

        float windMin;
        float windMax;
        float windCur;
        float tidal;
        float eIncome;
        float ePull;
        float eCur;
        float eStor;
        float mIncome;
        float mCur;
        float mStor;
        bool metalMap;
        int t1Cons;
        int t2Cons;
        bool t2Lab;
        int t2LabQueued;
        AIFloat3 mexUpPos;          // nearest owned T1 mex a T2 builder could upgrade (x < 0: none)
        int mexUpsQueued;
        int solars;
        int advSolars;
        int winds;
        int t1Convs;
        int advConvs;
        int t1ConvsQueued;
        int advConvsQueued;
        int fusions;
        int afus;
        bool fusionUp = false;
        bool afusStarted = false;
        bool conversionAllowed = true;
        int estors;
        int mstors;
        int estorsQueued;
        int mstorsQueued;
        int nanosQueued;            // turret orders not yet started
        int nanosBuilding;          // turrets under construction
        bool turretSlot;            // a planned turret slot is left (Layout::CanPlaceTurret)
        bool builderIsCommander;
        float buildPowerNear;       // static assist build power around the base (turrets), workertime units
        bool builderIsT2;
        const CCircuitDef@ builderDef;    // the asking constructor: only its build options are offered (CR-006)
        bool energyBuilding;        // an energy structure of ours is ordered or under construction
        bool energyAssistable;      // ... and its frame exists within EcoAssistRadius of the asking builder
    }

    class Option {
        string key;             // "solar", "advsolar", "wind", "tidal", "fusion", "afus", "t1conv", "advconv", "estor", "mstor", "nano"
        CCircuitDef@ def;
        float cost;             // metal
        float output;           // E/s (energy sources), M/s (converters)
        float metalPerE;        // cost / output for energy sources
        float energyUse;        // converter draw
        float metalMake;        // converter output
        bool tier2;
    }

    string lastChoice = "";
    int lastLogFrame = -100000;
    int lastT2GateLog = -100000;

    // ---------------------------------------------------------------- numbers

    // Energy output per def (E/s). The script API has no energyMake; these are
    // the game's values (rjm.bar.docs knowledge/50-economy/50-income-sources.md).
    float OutputOf(const string &in name, const State@ s)
    {
        if (name == "armsolar" || name == "corsolar" || name == "legsolar") return 20.0f;
        if (name == "armadvsol" || name == "coradvsol") return 80.0f;
        if (name == "legadvsol") return 100.0f;
        if (name == "armwin" || name == "corwin" || name == "legwin") return WindEffective(s);
        if (name == "armtide" || name == "cortide" || name == "legtide") return s.tidal;
        if (name == "armgeo" || name == "corgeo" || name == "leggeo") return 300.0f;
        if (name == "armfus") return 750.0f;
        if (name == "corfus") return 850.0f;
        if (name == "legfus") return 950.0f;
        if (name == "armafus" || name == "corafus") return 3000.0f;
        if (name == "legafus") return 3300.0f;
        return 0.0f;
    }

    // A wind turbine's effective output: the map's average, capped by the
    // turbine's nominal 25, and discounted when the lulls go below the floor
    // (a base on wind alone stalls in a lull; storage and solars cover it).
    float WindEffective(const State@ s)
    {
        const float avg = (s.windMin + s.windMax) * 0.5f;
        float eff = AiMin(avg, 25.0f);
        if (s.windMin < Global::RoleSettings::Tech::EcoWindLullFloor) eff *= Global::RoleSettings::Tech::EcoWindLullFactor;
        return eff;
    }

    // The energy income a metal income wants: EcoEnergyRatioLow E per M at
    // EcoEnergyRampStart metal, rising to EcoEnergyRatioHigh by EcoEnergyRampEnd.
    // (Played: the old 25 per M from +18 asked +16 metal for 456 E, sixty
    // turbines on a 1-19 wind map, and every metal went to energy.)
    float TargetEnergy(float m)
    {
        const float span = Global::RoleSettings::Tech::EcoEnergyRampEnd - Global::RoleSettings::Tech::EcoEnergyRampStart;
        float r = Global::RoleSettings::Tech::EcoEnergyRatioLow
            + (m - Global::RoleSettings::Tech::EcoEnergyRampStart)
                * (Global::RoleSettings::Tech::EcoEnergyRatioHigh - Global::RoleSettings::Tech::EcoEnergyRatioLow) / ((span > 1.0f) ? span : 1.0f);
        if (r < Global::RoleSettings::Tech::EcoEnergyRatioLow) r = Global::RoleSettings::Tech::EcoEnergyRatioLow;
        if (r > Global::RoleSettings::Tech::EcoEnergyRatioHigh) r = Global::RoleSettings::Tech::EcoEnergyRatioHigh;
        return r * m + Global::RoleSettings::Tech::EcoEnergyReserve;
    }

    // The assist build power a metal income can keep busy (doc/eco-planner.md:
    // about 8 BP per metal per second spends the income on T2 work).
    float TargetBuildPower(float m, bool floating)
    {
        return m * Global::RoleSettings::Tech::EcoBuildPowerPerMetal
            * (floating ? Global::RoleSettings::Tech::EcoBuildPowerFloatFactor : 1.0f);
    }

    // ---------------------------------------------------------------- state

    State@ Read(CCircuitUnit@ u, float metalIncome, float energyIncome, bool air = false)
    {
        if (AiPerfEnabled) AiPerfBegin(2);
        State@ result = ReadMeasured(u, metalIncome, energyIncome, air);
        if (AiPerfEnabled) AiPerfEnd(2);
        return result;
    }

    State@ ReadMeasured(CCircuitUnit@ u, float metalIncome, float energyIncome, bool air)
    {
        State@ s = State();
        s.air = air;
        s.windMin = ai.GetWindMin();
        s.windMax = ai.GetWindMax();
        s.windCur = ai.GetWindCur();
        s.tidal = ai.GetTidalStrength();
        s.eIncome = energyIncome;
        s.ePull = aiEconomyMgr.energy.pull;
        s.eCur = aiEconomyMgr.energy.current;
        s.eStor = aiEconomyMgr.energy.storage;
        s.mIncome = metalIncome;
        s.mCur = aiEconomyMgr.metal.current;
        s.mStor = aiEconomyMgr.metal.storage;
        s.metalMap = ai.GetMetalSpotCount() >= Global::RoleSettings::Tech::EcoMetalMapSpots;
        s.t1Cons = UnitDefHelpers::SumUnitDefCounts(air ? UnitHelpers::GetAllT1AirConstructors() : UnitHelpers::GetAllT1BotConstructors());
        s.t2Cons = UnitDefHelpers::SumUnitDefCounts(air ? UnitHelpers::GetAllT2AirConstructors() : UnitHelpers::GetAllT2BotConstructors());
        s.t2Lab = air || TechFlank::NormalLabCount() > 0; // AIR owns its separate aircraft-lab gate
        {
            CCircuitDef@ t2lab = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
            s.t2LabQueued = (t2lab is null) ? 0 : aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), t2lab);
        }
        const string side = Global::AISettings::Side;
        s.solars = Count(UnitHelpers::GetSolarNameForSide(side));
        s.advSolars = Count(UnitHelpers::GetAdvSolarNameForSide(side));
        s.winds = Count(UnitHelpers::GetWindNameForSide(side));
        s.t1Convs = Count(UnitHelpers::GetEnergyConverterNameForSide(side));
        s.advConvs = Count(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
        s.t1ConvsQueued = Queued(UnitHelpers::GetEnergyConverterNameForSide(side), Task::BuildType::CONVERT);
        s.advConvsQueued = Queued(UnitHelpers::GetAdvEnergyConverterNameForSide(side), Task::BuildType::CONVERT);
        s.fusions = Count(UnitHelpers::GetFusionNameForSide(side));
        s.afus = Count(UnitHelpers::GetAdvFusionNameForSide(side));
        if (air) {
            s.conversionAllowed = !ProductionMath::MetalFloating(s.mCur, s.mStor);
            s.fusionUp = AirEconomy::HasReactor();
            s.afusStarted = s.afus > 0 || Queued(UnitHelpers::GetAdvFusionNameForSide(side), Task::BuildType::ENERGY) > 0;
        }
        s.estors = Count(UnitHelpers::GetEnergyStorageNameForSide(side));
        s.mstors = Count(UnitHelpers::GetMetalStorageNameForSide(side));
        s.estorsQueued = Queued(UnitHelpers::GetEnergyStorageNameForSide(side), Task::BuildType::STORE);
        s.mstorsQueued = Queued(UnitHelpers::GetMetalStorageNameForSide(side), Task::BuildType::STORE);
        s.nanosQueued = Queued(UnitHelpers::GetT1NanoNameForSide(side), Task::BuildType::NANO);
        {
            CCircuitDef@ nanoDef = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
            s.nanosBuilding = (nanoDef is null) ? 0 : aiBuilderMgr.GetUnfinishedCount(nanoDef);
        }
        s.builderIsCommander = (u !is null) && UnitHelpers::IsCommander(u.circuitDef);
        s.turretSlot = air ? AirEconomy::t1 + AirEconomy::t2 > 0 : Layout::CanPlaceTurret();
        // Turrets only: the commander's 300 and the constructors' 90s pass
        // through; played, they hid the shortage and no turret was ever built.
        s.buildPowerNear = aiBuilderMgr.GetStaticBuildPowerNear(air ? Global::Map::StartPos : Layout::BaseCentre(),
            air ? Global::RoleSettings::Air::HomeEconomyRadius : Global::RoleSettings::Tech::EcoBuildPowerRadius);
        s.builderIsT2 = (u !is null && u.circuitDef !is null) ? (UnitHelpers::GetConstructorTier(u.circuitDef) >= 2) : false;
        s.mexUpPos = AIFloat3(-1.0f, 0.0f, -1.0f);
        s.mexUpsQueued = 0;
        if (s.builderIsT2 && !air) {
            CCircuitDef@ t2mex = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(side));
            if (t2mex !is null && u.circuitDef.CanBuild(t2mex)) {
                s.mexUpsQueued = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEXUP), t2mex);
                s.mexUpPos = Economy::MexTracker::GetNearestNonUpgradedMexInRange(u.GetPos(ai.frame), Global::Map::StartPos,
                    Global::RoleSettings::MexUpgradeRadius, u, t2mex);
            }
        }
        @s.builderDef = (u is null) ? null : u.circuitDef;
        // An energy structure is "in progress" from the order on, not only once
        // its frame exists: played, two advanced solars were started at once
        // while the first constructor was still walking.
        s.energyBuilding = (Builder::GetEnergyUnderConstruction() !is null)
            || (aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), null) > 0);
        s.energyAssistable = false;
        {
            CCircuitUnit@ frame = Builder::GetEnergyUnderConstruction();
            if (frame !is null && u !is null) {
                const float r = Global::RoleSettings::Tech::EcoAssistRadius;
                s.energyAssistable = MapHelpers::SqDist(frame.GetPos(ai.frame), u.GetPos(ai.frame)) <= r * r;
            }
        }
        return s;
    }

    // A def the constructor could build now: exists, available (not capped)
    // and the box holds it. The storage rules used to name a capped metal
    // storage every ask (TECH caps it at 0 until the advanced lab).
    bool Buildable(const string &in name, const State@ s)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !d.IsAvailable(ai.frame)) return false;
        if (s.builderDef !is null && !s.builderDef.CanBuild(d)) return false;
        return s.air || Layout::CanPlace(d);
    }

    int Count(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        return (d is null) ? 0 : d.count;
    }

    int Queued(const string &in name, Task::BuildType type)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        return (d is null) ? 0 : aiBuilderMgr.GetQueuedBuildCount(int(type), d);
    }

    Option@ Make(const string &in key, const string &in name, const State@ s, bool tier2)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        // Only what the asking constructor can build: a commander has no
        // advanced solar, a T1 constructor no fusion (CR-006).
        if (s.builderDef !is null && !s.builderDef.CanBuild(d)) return null;
        if (s.air) {
            if (!AirMath::EnergyEraAllows(key == "wind" || key == "solar", key == "advsolar", s.fusionUp, s.afusStarted)) return null;
        } else if (Global::energyAllowed !is null && !Global::energyAllowed(name)) return null;   // D-077: no T1 energy in the fusion era
        // Only what the turret box holds within a turret's reach (D-063).
        if (!s.air && !Layout::CanPlace(d)) {
            if (Global::AISettings::Role == AiRole::TECH && (key == "t1conv" || key == "advconv")
                && conversionDecision !is null) {
                conversionDecision.placementRejected = true;
                conversionDecision.placementRejectedDef = d.id;
            }
            return null;
        }
        Option@ o = Option();
        o.key = key;
        @o.def = d;
        o.cost = d.costM;
        o.output = OutputOf(name, s);
        o.metalPerE = (o.output > 0.0f) ? o.cost / o.output : 1.0e9f;
        o.energyUse = (key == "t1conv" || key == "advconv") ? aiEconomyMgr.GetEnergyUse(d) : 0.0f;
        o.metalMake = (key == "t1conv" || key == "advconv") ? aiEconomyMgr.GetMetalMake(d) : 0.0f;
        o.tier2 = tier2;
        return o;
    }

    bool Affordable(const Option@ o, const State@ s)
    {
        return o.cost <= s.mCur + Global::RoleSettings::Tech::EcoAffordSeconds * s.mIncome;
    }

    // The energy sources this constructor could build now, cheapest metal per E/s first.
    // D-199: return one privately owned array handle. Value assignments at
    // callers copy the array; PickEnergy needs ownership because it filters.
    // Stable insertion below preserves equal-payback choices/random behavior.
    // See doc/performance/engineering-guide.md and check_performance_policy.py.
    array<Option@>@ EnergyOptions(const State@ s)
    {
        const string side = Global::AISettings::Side;
        array<Option@> opts;
        Option@ o;
        @o = Make("solar", UnitHelpers::GetSolarNameForSide(side), s, false); if (o !is null) opts.insertLast(o);
        @o = Make("advsolar", UnitHelpers::GetAdvSolarNameForSide(side), s, false);
        if (o !is null && (s.mIncome >= Global::RoleSettings::Tech::EcoAdvSolarMinMetalIncome || s.mCur >= o.cost)) opts.insertLast(o);
        @o = Make("wind", UnitHelpers::GetWindNameForSide(side), s, false);
        if (o !is null && WindEffective(s) >= Global::RoleSettings::Tech::EcoWindMinimum) opts.insertLast(o);
        if (s.builderIsT2 && s.allowReactors) {
            @o = Make("fusion", UnitHelpers::GetFusionNameForSide(side), s, true);
            if (o !is null && s.mIncome >= Global::RoleSettings::Tech::MinimumMetalIncomeForFUS) opts.insertLast(o);
            @o = Make("afus", UnitHelpers::GetAdvFusionNameForSide(side), s, true);
            if (o !is null && s.mIncome >= Global::RoleSettings::Tech::MinimumMetalIncomeForAFUS) opts.insertLast(o);
        }
        // affordable first, then metal per E/s, then the larger output
        // Stable insertion in the owned array: preserve ties and comparison
        // order without allocating a second GC array or copying on return.
        for (uint i = 1; i < opts.length(); ++i) {
            Option@ c = opts[i];
            uint at = i;
            for (uint k = 0; k < i; ++k) {
                const bool ca = Affordable(c, s);
                const bool ka = Affordable(opts[k], s);
                if (ca && !ka) { at = k; break; }
                if (ca == ka && (c.metalPerE < opts[k].metalPerE || (c.metalPerE == opts[k].metalPerE && c.output > opts[k].output))) { at = k; break; }
            }
            for (uint k = i; k > at; --k) @opts[k] = opts[k - 1];
            @opts[at] = c;
        }
        return opts;
    }

    // The cheapest energy per E/s the bank can pay; else the cheapest lump.
    // With a T2 builder asking and energy income at EcoFusionEnergyIncome or
    // more, the reactor is the answer whatever the ratio says: the base has
    // outgrown solars (owner's rule; played, advanced solars kept coming).
    string PickEnergy(const State@ s, string &out why, const string &in reason)
    {
        array<Option@>@ opts = EnergyOptions(s); // this owned list is filtered below
        // D-100 (owner: the fusion comes sooner once the mexes near it are
        // upgraded; played: energy.short ordered the fusion with 3 of 8 upgraded,
        // the upgrades' own drain making energy short): while upgrades are
        // pending the rows answer with the other energy, the chain orders the fusion
        const bool mohos = s.air ? !AirEconomy::MexesReady() : TechChain::MohosPending();
        const string rsn = mohos ? (reason + "; mex upgrades pending, no fusion") : reason;
        if (mohos) {
            for (int i = int(opts.length()) - 1; i >= 0; --i)
                if (opts[i].key == "fusion" || opts[i].key == "afus") opts.removeAt(uint(i));
        }
        if (opts.length() == 0) return "";
        if (s.builderIsT2 && s.eIncome >= Global::RoleSettings::Tech::EcoFusionEnergyIncome) {
            for (uint i = 0; i < opts.length(); ++i) {
                if (opts[i].key == "afus") { why = rsn + "; T2 builder above " + int(Global::RoleSettings::Tech::EcoFusionEnergyIncome) + " energy: advanced fusion"; return "afus"; }
            }
            for (uint i = 0; i < opts.length(); ++i) {
                if (opts[i].key == "fusion") { why = rsn + "; T2 builder above " + int(Global::RoleSettings::Tech::EcoFusionEnergyIncome) + " energy: fusion"; return "fusion"; }
            }
        }
        if (Affordable(opts[0], s)) {
            why = rsn + "; cheapest per E/s";
            return opts[0].key;
        }
        Option@ cheapest = opts[0];
        for (uint i = 1; i < opts.length(); ++i) if (opts[i].cost < cheapest.cost) @cheapest = opts[i];
        why = rsn + "; nothing affordable, cheapest lump";
        return cheapest.key;
    }

    // A converter the surplus carries: advanced for a T2 constructor at the
    // income floor, else T1 while the T1 ceiling allows.
    string PickConverter(const State@ s, float surplus, string &out why)
    {
        if (!s.conversionAllowed) return "";
        const string side = Global::AISettings::Side;
        // D-079: while energy floats (the chain's bank-based test) converters go
        // ConverterParallel at a time and the surplus is read as at least half
        // the income, the pull being inflated by whatever is under construction
        // (played: one T2 converter in three and a half minutes at a full bank)
        const bool floats = s.air ? s.eStor > 0.0f && s.eCur >= s.eStor * Global::RoleSettings::Tech::EcoConvertEnergyPercent : TechChain::EnergyBankFloats();
        const int par = floats ? Global::RoleSettings::Tech::ConverterParallel : 1;
        if (floats && surplus < s.eIncome * 0.5f) surplus = s.eIncome * 0.5f;
        if (Global::AISettings::Role == AiRole::TECH)
            surplus = AiMin(surplus, ConversionSupply());
        Option@ adv = Make("advconv", UnitHelpers::GetAdvEnergyConverterNameForSide(side), s, true);
        if (s.builderIsT2 && adv !is null && s.advConvsQueued < par
            && surplus >= adv.energyUse
            && (s.mIncome >= Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter
                || (Global::AISettings::Role == AiRole::TECH && FundedConverterRecovery(DefOf("advconv"), s.advConvsQueued)))) {
            why = "energy floating, surplus " + int(surplus) + " carries "
                + int(adv.energyUse) + " E/s advanced converter for +" + int(adv.metalMake) + " metal";
            return adv.key;
        }
        Option@ t1 = Make("t1conv", UnitHelpers::GetEnergyConverterNameForSide(side), s, false);
        if (t1 !is null && s.t1ConvsQueued < par
            && (!s.builderIsT2 || s.mIncome < Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter)
            && surplus >= t1.energyUse
            && s.mIncome < Global::RoleSettings::Tech::BuildT1ConvertersUntilMetalIncome) {
            why = "energy floating, surplus " + int(surplus) + " carries " + int(t1.energyUse) + " E/s T1 converter";
            return t1.key;
        }
        return "";
    }

    // The advanced lab as soon as its income gate passes: it is the step that
    // unlocks T2 constructors (mex upgrades, advanced converters, fusions),
    // so nothing but a stall outranks it. Played: metal floated at +20 for
    // minutes while the planner chose storage.
    string PickT2Lab(const State@ s, string &out why)
    {
        if (s.t2Lab || s.t2LabQueued > 0 || s.builderDef is null) return "";
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT2BotLabForSide(Global::AISettings::Side));
        if (lab is null || !lab.IsAvailable(ai.frame) || !s.builderDef.CanBuild(lab)) return "";
        if (MetalEconomy::Active()) {
            MetalEconomy::Read();
            if (MetalEconomy::workers[2] < 0) return "";
            why = "metal field: third constructor initiates T2";
            return "t2lab";
        }
        if (s.mIncome < Global::RoleSettings::Tech::MinimumMetalIncomeForT2Lab
            || s.eIncome < Global::RoleSettings::Tech::MinimumEnergyIncomeForT2Lab) {
            if (ai.frame - lastT2GateLog > 60 * SECOND) {
                lastT2GateLog = ai.frame;
                GenericHelpers::LogUtil("[Eco] advanced lab waits: +" + int(s.mIncome) + " metal, " + int(s.eIncome)
                    + " energy under the gate (" + int(Global::RoleSettings::Tech::MinimumMetalIncomeForT2Lab) + " / "
                    + int(Global::RoleSettings::Tech::MinimumEnergyIncomeForT2Lab) + ")", 1);
            }
            return "";
        }
        why = "advanced lab: +" + int(s.mIncome) + " metal, " + int(s.eIncome) + " energy clear the gate";
        return "t2lab";
    }

    // A T2 builder upgrades the nearest owned T1 mex within MexUpgradeRadius
    // of the start: the best metal per cost there is, and the reason the lab
    // came first. Played: with native's chooser closed, no upgrade ever came.
    string PickMexUpgrade(const State@ s, string &out why)
    {
        if (!s.builderIsT2 || s.mexUpPos.x < 0.0f) return "";
        if (s.mexUpsQueued >= Global::RoleSettings::MexUpgradeMaxConcurrent) return "";
        why = "T2 builder; owned mex at (" + int(s.mexUpPos.x) + ", " + int(s.mexUpPos.z) + ") to upgrade";
        return "mexup";
    }

    // Build power: a turret when the assist power around the base is under
    // the target for this income (or metal floats), a slot is planned and
    // the constructor can build one. One at a time: an order not yet started
    // or a turret under construction counts as the one in flight, and a
    // constructor that asks meanwhile assists it ("assistnano") instead of
    // starting another - build power is focused, not spread.
    string PickTurret(const State@ s, bool floatingM, string &out why)
    {
        if (!s.air && Layout::TurretsCapped()) {   // D-097: the calculation, not a fixed 1
            if (s.nanosBuilding > 0 && !s.builderIsCommander && s.builderDef !is null && s.builderDef.IsMobile()) {
                why = "a turret is under construction; assist it";
                return "assistnano";
            }
            return "";
        }
        if (!s.turretSlot) return "";
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        if (nano is null || !nano.IsAvailable(ai.frame) || s.builderDef is null || !s.builderDef.CanBuild(nano)) return "";
        if (s.mIncome < Global::RoleSettings::Tech::EcoTurretMinMetalIncome) return "";
        if (s.mCur < nano.costM * Global::RoleSettings::Tech::EcoTurretBankFraction) return "";
        const float target = TargetBuildPower(s.mIncome, floatingM);
        if (s.buildPowerNear >= target) return "";
        why = "build power " + int(s.buildPowerNear) + " under " + int(target) + " for +" + int(s.mIncome) + " metal; turret";
        if (floatingM) why = "metal floating at " + int(s.mCur) + ", " + why;
        return "nano";
    }

    // ---------------------------------------------------------------- the decision

    // Returns the key of the structure to build next, "" for none; `why` says why.
    string Decide(const State@ s, string &out why)
    {
        const float target = AiMax(TargetEnergy(s.mIncome), s.energyGoal);
        const float deficit = target - s.eIncome;
        const bool draining = (s.eStor > 0.0f) && (s.eCur < Global::RoleSettings::Tech::EcoEnergyLowPercent * s.eStor) && (s.ePull > s.eIncome);
        const bool floatingE = (s.eStor > 0.0f) && (s.eCur >= Global::RoleSettings::Tech::EcoConvertEnergyPercent * s.eStor);
        const float surplus = s.eIncome - s.ePull;
        const bool floatingM = aiEconomyMgr.isMetalFull
            || ((s.mStor > 0.0f) && (s.mCur >= Global::RoleSettings::Tech::EcoFloatMetalPercent * s.mStor) && (s.mIncome >= 5.0f));
        const bool oneAtATime = s.energyBuilding && Global::RoleSettings::Tech::EcoOneEnergyAtATime;
        string key;

        // 1. energy draining: the base is stalling, energy before anything -
        //    but one structure at a time even now. A second builder asking
        //    while one is going up assists it if it is within EcoAssistRadius
        //    (build power focused, walking capped); played, three advanced
        //    solars went up in parallel.
        if (draining) {
            if (!s.energyBuilding) {
                key = PickEnergy(s, why, "energy draining, bank " + int(s.eCur) + "/" + int(s.eStor) + ", pull " + int(s.ePull) + " over " + int(s.eIncome));
                if (key.length() > 0) return key;
            } else if (s.energyAssistable) {
                why = "energy draining and a structure is going up; assist it";
                return "assistenergy";
            }
        }

        // 2. the advanced lab the moment its gate passes.
        key = PickT2Lab(s, why);
        if (key.length() > 0) return key;

        // 2b. a T2 builder upgrades the owned mexes first.
        key = PickMexUpgrade(s, why);
        if (key.length() > 0) return key;

        // 3. energy floating, or a surplus that carries a converter twice over:
        //    convert it. Energy under construction does not block this - a
        //    converter turns surplus into metal, and the surplus is measured.
        if (s.allowConverters && (floatingE || (surplus >= 2.0f * Global::RoleSettings::Tech::EcoConverterUse)) && !aiEconomyMgr.isEnergyStalling) {
            key = PickConverter(s, surplus, why);
            if (key.length() > 0) return key;
        }

        // 4. metal floating or build power short: a construction turret.
        key = PickTurret(s, floatingM, why);
        if (key.length() > 0) return key;

        // 5. energy below the target for this income, and not floating: one
        //    structure at a time (D-037). A full bank is not a shortage. Once
        //    a T2 constructor exists and energy income is past the fusion
        //    threshold, T1 builders leave energy to the reactors.
        const bool fusionEra = (s.t2Cons > 0) && (s.eIncome >= Global::RoleSettings::Tech::EcoFusionEnergyIncome);
        if (deficit > 0.0f && !floatingE && !oneAtATime && (s.builderIsT2 || !fusionEra)) {
            key = PickEnergy(s, why, "energy " + int(s.eIncome) + " below target " + int(target));
            if (key.length() > 0) return key;
        }
        if (deficit > 0.0f && !floatingE && oneAtATime && s.energyAssistable) {
            why = "energy below target and a structure is going up; assist it";
            return "assistenergy";
        }

        // 6. storage
        if (s.winds >= Global::RoleSettings::Tech::EcoStorageWinds
            && s.estors + s.estorsQueued < 1 && s.mIncome >= 4.0f && Buildable(UnitHelpers::GetEnergyStorageNameForSide(Global::AISettings::Side), s)) {
            why = s.winds + " winds and no energy storage: buffer the lulls";
            return "estor";
        }
        if (s.estors + s.estorsQueued < Global::RoleSettings::Tech::EcoMaxEnergyStorages
            && s.eStor < s.eIncome * Global::RoleSettings::Tech::EcoStorageSeconds && s.mIncome >= 15.0f
            && s.mCur >= Global::RoleSettings::Tech::EcoStorageMinMetalBank
            && Buildable(UnitHelpers::GetEnergyStorageNameForSide(Global::AISettings::Side), s)) {
            why = "energy storage holds under " + int(Global::RoleSettings::Tech::EcoStorageSeconds) + " s of income";
            return "estor";
        }
        if (aiEconomyMgr.isMetalFull && s.mstors + s.mstorsQueued < Global::RoleSettings::Tech::EcoMaxMetalStorages && s.mIncome >= 20.0f
            && Buildable(UnitHelpers::GetMetalStorageNameForSide(Global::AISettings::Side), s)) {
            why = "metal bank full at +" + int(s.mIncome) + "; metal storage";
            return "mstor";
        }

        // 7. metal floating with energy ahead: the best payback anyway, up to twice the target.
        if (floatingM && s.eIncome < 2.0f * target && !oneAtATime) {
            const array<Option@>@ opts = EnergyOptions(s);
            for (uint i = 0; i < opts.length(); ++i) {
                if (Affordable(opts[i], s)) {
                    why = "metal floating at " + int(s.mCur) + "; best payback energy";
                    return opts[i].key;
                }
            }
        }
        why = "";
        return "";
    }

    // ---------------------------------------------------------------- execution

    CCircuitDef@ DefOf(const string &in key)
    {
        const string side = Global::AISettings::Side;
        if (key == "solar") return ai.GetCircuitDef(UnitHelpers::GetSolarNameForSide(side));
        if (key == "advsolar") return ai.GetCircuitDef(UnitHelpers::GetAdvSolarNameForSide(side));
        if (key == "wind") return ai.GetCircuitDef(UnitHelpers::GetWindNameForSide(side));
        if (key == "t1conv") return ai.GetCircuitDef(UnitHelpers::GetEnergyConverterNameForSide(side));
        if (key == "advconv") return ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
        if (key == "fusion") return ai.GetCircuitDef(UnitHelpers::GetFusionNameForSide(side));
        if (key == "afus") return ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(side));
        if (key == "estor") return ai.GetCircuitDef(UnitHelpers::GetEnergyStorageNameForSide(side));
        if (key == "mstor") return ai.GetCircuitDef(UnitHelpers::GetMetalStorageNameForSide(side));
        if (key == "nano") return ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        return null;
    }

    Task::BuildType TypeOf(const string &in key)
    {
        if (key == "t1conv" || key == "advconv") return Task::BuildType::CONVERT;
        if (key == "estor" || key == "mstor") return Task::BuildType::STORE;
        if (key == "nano") return Task::BuildType::NANO;
        return Task::BuildType::ENERGY;
    }

    int TimeoutOf(const string &in key)
    {
        if (key == "fusion" || key == "afus") return SECOND * 300;
        if (key == "t1conv") return SECOND * 30;
        if (key == "solar" || key == "advsolar") return SECOND * 75;
        return SECOND * 60;
    }

    // The structure goes on the turret box cells nearest a turret, pinned;
    // a turret goes on its planned slot. Null when the box has no room: the
    // caller continues its ladder and never spirals for it (D-063).
    IUnitTask@ Enqueue(const string &in key, CCircuitUnit@ u)
    {
        if (MetalEconomy::Active() && (key == "t1conv" || key == "advconv")) return null;
        if (key == "nano") return Layout::NanoTask(u, Task::Priority::HIGH);
        if (key == "mexup") {
            if (MetalEconomy::Active()) return aiEconomyMgr.EnqueueFieldUpgrade(u, Global::Map::StartPos, MetalEconomy::HomeRadius);
            CCircuitDef@ t2mex = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(Global::AISettings::Side));
            AIFloat3 at = Economy::MexTracker::GetNearestNonUpgradedMexInRange(u.GetPos(ai.frame), Global::Map::StartPos,
                Global::RoleSettings::MexUpgradeRadius, u, t2mex);
            if (t2mex is null || at.x < 0.0f) return null;
            return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, t2mex, at, -1));
        }
        if (key == "t2lab") {
            // The site is the layout's call (D-069): the pair's slot or the
            // footprint the most static build power reaches.
            return Layout::T2LabTask(300 * SECOND);
        }
        if (key == "assistenergy") {
            return Builder::EnqueueAssistEnergy(Task::Priority::HIGH, 60 * SECOND, Global::RoleSettings::Tech::EnergyFocusMaxAssists);
        }
        if (key == "assistnano") {
            CCircuitDef@ nanoDef = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
            CCircuitUnit@ target = (nanoDef is null) ? null
                : aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoTurretAssistRadius, nanoDef);
            if (target is null) return null;
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, target, 90 * SECOND));
        }
        CCircuitDef@ def = DefOf(key);
        if (def is null || !def.IsAvailable(ai.frame)) return null;
        const bool techConverter = Global::AISettings::Role==AiRole::TECH && (key=="t1conv" || key=="advconv");
        if (techConverter) {
            const ConversionReason admission = TechConversionAdmission(def, u);
            if (admission != READY) { TraceConversion(u, admission); return null; }
        }
        // INV-032 (D-105): no converter is ordered while the metal bank is full
        if ((key == "t1conv" || key == "advconv") && TechBuild::MetalFullLong())
            Invariants::Violation("INV-032", key, "a " + def.GetName() + " ordered with the metal bank full for " + int(Global::RoleSettings::Tech::PowerAheadSeconds) + " s");
        const Task::BuildType type = TypeOf(key);
        if (Global::AISettings::Role == AiRole::TECH && (key == "fusion" || key == "afus")) {
            if (!TechBuild::EnergyAllowed(def.GetName())) return null;
            // One existing reactor commitment owns construction, including its
            // travel to an unframed site. Retain the normal assist mechanism.
            if (Builder::EnergyBuildTask !is null && !Builder::EnergyBuildTask.IsDead())
                return Builder::EnqueueAssistEnergy(Task::Priority::HIGH, 60 * SECOND,
                    Global::RoleSettings::Tech::EnergyFocusMaxAssists);
        }
        const Task::Priority prio = (key == "fusion" || key == "afus") ? Task::Priority::HIGH : Task::Priority::NORMAL;
        IUnitTask@ t = Layout::Place(type, prio, def, TimeoutOf(key), u);
        if (techConverter) {
            if (conversionDecision !is null) {
                conversionDecision.read = false; // an enqueue changes committed capacity immediately
                conversionDecision.placementRejected = t is null;
                conversionDecision.placementRejectedDef = t is null ? def.id : -1;
            }
            TraceConversion(u, t is null ? PLACEMENT : PENDING);
        }
        if (t !is null && type == Task::BuildType::ENERGY) Builder::_SetEnergyBuildTask(t);
        return t;
    }

    // The next structure for this constructor as a key, "" when the economy
    // wants nothing from it now. The caller applies the role's "assist the
    // reactor under construction instead" rule, then Execute.
    string Next(CCircuitUnit@ u, float metalIncome, float energyIncome)
    {
        if (MetalEconomy::Active()) return ""; // one field controller owns economy selection
        // With the experimental system on, the rule table (roles/tech_rules.as)
        // calls the Pick* pieces itself and this entry answers nothing, so the
        // legacy rungs it still reuses cannot run the planner a second time.
        if (Global::RoleSettings::Tech::ExperimentalBuild || !Global::RoleSettings::Tech::EcoPlannerEnabled || u is null) return "";
        State@ s = Read(u, metalIncome, energyIncome);
        string why;
        const string key = Decide(s, why);
        if (key.length() == 0) return "";
        if (key != lastChoice || ai.frame - lastLogFrame > 30 * SECOND) {
            lastChoice = key;
            lastLogFrame = ai.frame;
            string who = "?";
            if (s.builderDef !is null) who = s.builderDef.GetName();
            GenericHelpers::LogUtil("[Eco] next: " + key + " (" + why + ") | E " + int(s.eIncome) + "/" + int(TargetEnergy(s.mIncome))
                + " pull " + int(s.ePull) + " bank " + int(s.eCur) + "/" + int(s.eStor) + " | M +" + int(s.mIncome) + " bank " + int(s.mCur)
                + " | BP " + int(s.buildPowerNear) + "/" + int(TargetBuildPower(s.mIncome, false)) + " turrets in flight " + (s.nanosQueued + s.nanosBuilding) + " slot " + (s.turretSlot ? "yes" : "no")
                + " | wind " + int(s.windMin) + "-" + int(s.windMax) + " eff " + int(WindEffective(s)) + " tidal " + int(s.tidal)
                + " | by " + who, 1);
        }
        return key;
    }

    IUnitTask@ Execute(const string &in key, CCircuitUnit@ u)
    {
        if (key.length() == 0 || u is null) return null;
        return Enqueue(key, u);
    }
}
