// AIR role: T2 bomber waves.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../manager/military.as"
#include "../../helpers/math/air_math.as"
#include "air_operations.as"

/******************************************************************************

T2 BOMBER WAVES

D-171: ExperimentalBuild opts into funded, committed bomber operations in
doc/air-committed-operations-plan.md. Offensive survivors keep attacking;
defensive sorties may return and repair. Experimental T1 raids live in
air_raids.as. The historical description below applies to the legacy branch.

Native CMilitaryManager::DefaultMakeTask puts every unit whose main role is
"bomber" into a CBombTask the moment it leaves the factory, so bombers trickle
out one at a time. That is the right opening behaviour for T1 bombers and is
left untouched (every def not in UnitHelpers::GetAllT2WaveBombers /
GetAllT2Fighters falls through to the default task). T2 bombers and T2 fighters
are instead held at base and released together, escorted, in waves that grow
with every launch. BAR has no T3 bombers (the experimental aircraft plants are
unreachable and gantries build no aircraft); the wave roster is data-driven in
UnitHelpers, so a new tier is a list entry.

Native primitives used (no C++ required):
  hold     TaskF::Defend(check=MELEE, promote=BOMB|AA, power=HoldPower). A
           CDefendTask parks the unit near the base position and only engages
           enemies inside our own defence influence. It promotes when
           attackPower >= power or when any task of type `check` exists: MELEE
           tasks are never created (CMilitaryManager::Enqueue has no MELEE case)
           and HoldPower is far above any real sum, so a hold never promotes on
           its own. Promote is not ATTACK because UpdateDefenceTasks rewrites the
           power threshold of ATTACK-promoting defend tasks every 5 s. Holds of
           the same promote type merge natively; release therefore aborts by
           task, not by unit.
  release  IUnitTask::Abort() on every distinct hold task returns its units to
           CIdleTask. Each re-enters Military::AiMakeTask within a few seconds
           and is handed its wave task from the launch queue.
  wave     one TaskF::Common(BOMB) per bomber def: CBombTask::CanAssignTo only
           groups identical defs, and target selection stays native (see
           doc/bomber-targeting.md for its known defects). Fighters get
           TaskF::Guard(vip) on the wave's bombers, spread round-robin over the
           living bombers, so they fly with the wave and engage what comes near.
  end      no explicit end. CBombTask keeps bombing while it has targets;
           survivors that come back idle rejoin the hold for the next wave, and
           an escort whose bomber died re-attaches to another living wave bomber
           while the wave still has one.

Sizing (ComputeNextWaveSize): the next wave starts from the previous size and
grows by a factor picked from the previous wave's survival ratio, measured
BomberWaveEvaluateSeconds after launch: heavy losses mean the enemy anti-air is
winning and the next wave needs mass; light losses grow gently. The result is
raised to an enemy-anti-air floor (wave bomber metal >= a fraction of the enemy
anti_air metal on the map, from the Military cost cache) and clamped to
[BomberWaveFirstSize, BomberWaveMaxSize]. A wave also launches on a time-out
once BomberWaveFirstSize bombers have been held for BomberWaveMaxHoldSeconds,
so slow production never stalls the air war.

Production: the T2 aircraft plant asks MakeProductionTask for the next wave
unit; bombers and fighters are grown together so the escort never lags.

Income floor (D-045): whatever the survival growth says, a wave must hold
BomberWaveSizePerIncomeStep bombers for every BomberWaveIncomeStep of
sliding-minimum metal income - 50 at +100, 100 at +200 - before it launches.

Attack methods (D-045, doc/air-wave-attacks.md): each launch draws one of
CARPET / FLANK / PINCER / STRIKE / DEEP / FEINT by weight and hands every
bomber one native CAirWaveTask carrying the plan: form a line abreast at the
stand-off, hold if told, attack-move down parallel lanes through the aim
(carpet) or dive on the chosen unit (strike). When the run is over the task
aborts itself, the survivors are handed the plain native bomb task once
(mop-up, `mopUp`), and after that they rejoin the hold. With no wave task
(the enqueue failed) a launch falls back to the plain bomb tasks as before.

CCircuitUnit handles are not ref-counted: only ids are stored and units are
re-acquired with ai.GetTeamUnit(id). Task handles are ref-counted and are kept
only for the release window; Military::AiTaskRemoved drops them early.

******************************************************************************/
namespace AirWaves {
    const float HoldPower = 1.0e9f;   // never reached: hold tasks must not self-promote

    // ---- roster (built once in Init) ----
    dictionary waveBomberDefs;   // def name -> true
    dictionary waveFighterDefs;

    // ---- hold ----
    dictionary heldBombers;      // id string -> int id
    dictionary heldFighters;
    int holdSinceFrame = -1;     // first frame the bomber hold was non-empty since the last launch

    // ---- release / wave ----
    dictionary launchQueue;      // id string -> int id, released units awaiting a wave task
    dictionary waveBombers;      // id string -> int id, launched bombers still alive
    dictionary waveFighters;     // id string -> int id, launched escorts still alive
    dictionary evaluationCohort; // immutable launch IDs; returning does not mean dying
    int lastNoTargetLog = -100000;
    int targetMinimum = 0;
    int plannedCount = 0;
    bool plannedDefensive = false;
    bool plannedFront = false;
    int lastPlanFrame = -100000;
    float learnedResistance = 1.0f;
    AIFloat3 lastRaidAim;
    array<AIFloat3> failedRaidAims;
    array<int> failedRaidUntil;
    dictionary waveBombTasks;    // bomber def name -> IUnitTask@, release window only
    IUnitTask@ waveTask = null;  // the launched wave's CAirWaveTask, until it aborts itself
    dictionary mopUp;            // id string -> true: a native bomb task is still owed after the run
    int lastMethod = -1;         // Task::WaveMode of the last launch
    uint nextVipIdx = 0;
    int releaseUntilFrame = -1;  // >= 0 while released units are being re-tasked

    // ---- history / sizing ----
    int waveIndex = 0;
    int nextWaveSize = 0;
    int lastWaveSize = 0;
    int lastLaunchFrame = -1;
    int lastLaunchFighters = 0;
    bool lastWaveEvaluated = true;

    void Init()
    {
        waveBomberDefs.deleteAll();
        waveFighterDefs.deleteAll();
        {
            array<string> ids = UnitHelpers::GetAllT2WaveBombers();
            for (uint i = 0; i < ids.length(); ++i) waveBomberDefs.set(ids[i], true);
        }
        {
            array<string> ids = UnitHelpers::GetAllT2Fighters();
            for (uint i = 0; i < ids.length(); ++i) waveFighterDefs.set(ids[i], true);
        }
        heldBombers.deleteAll();
        heldFighters.deleteAll();
        launchQueue.deleteAll();
        waveBombers.deleteAll();
        waveFighters.deleteAll();
        evaluationCohort.deleteAll();
        targetMinimum = 0;
        plannedCount = 0;
        lastPlanFrame = -100000;
        learnedResistance = AirMath::Clamp(float(aiTerrainMgr.GetLayoutInt("air.raidRiskMilli", 1000)) / 1000.0f,
            1.0f, AiMax(1.0f, Global::RoleSettings::Air::StrikeLearnedRiskMax));
        failedRaidAims.resize(0);
        failedRaidUntil.resize(0);
        waveBombTasks.deleteAll();
        @waveTask = null;
        mopUp.deleteAll();
        lastMethod = -1;
        nextVipIdx = 0;
        holdSinceFrame = -1;
        releaseUntilFrame = -1;
        waveIndex = 0;
        nextWaveSize = Global::RoleSettings::Air::BomberWaveFirstSize;
        lastWaveSize = 0;
        lastLaunchFrame = -1;
        lastLaunchFighters = 0;
        lastWaveEvaluated = true;
        GenericHelpers::LogUtil("[AIR][Waves] Init: enabled=" + (IsEnabled() ? "yes" : "no")
            + " first=" + Global::RoleSettings::Air::BomberWaveFirstSize
            + " max=" + Global::RoleSettings::Air::BomberWaveMaxSize
            + " fighterRatio=" + Global::RoleSettings::Air::BomberWaveFighterRatio, 2);
    }

    bool IsEnabled() { return Global::RoleSettings::Air::BomberWavesEnabled; }
    bool IsWaveBomber(const CCircuitDef@ d)
    {
        if (d is null || !waveBomberDefs.exists(d.GetName())) return false;
        // EMP and specialist payloads require their own strike budgets/timing.
        return !Global::RoleSettings::Air::ExperimentalBuild || d.GetName() == "armpnix"
            || d.GetName() == "corhurc" || d.GetName() == "legphoenix";
    }
    bool IsWaveFighter(const CCircuitDef@ d) { return d !is null && waveFighterDefs.exists(d.GetName()); }

    // Fighters required to escort `bombers` (ratio rounded up).
    // Escorts primarily counter enemy aircraft. The AA-priority gadget often
    // favors bombers, so escorts are not a reliable shield against ground AA.
    // Commands, range and mixed contacts can change that targeting; no immunity
    // is assumed. Escort demand scales with observed enemy air investment.
    float EscortRatio()
    {
        const float ratio = Global::RoleSettings::Air::BomberWaveFighterRatio;
        if (ratio <= 0.0f) return 0.0f;
        const float enemyAir = Global::RoleSettings::Air::ExperimentalBuild ? AirEconomy::EnemyAir()
            : Military::GetCachedRoleCost("air") + Military::GetCachedRoleCost("bomber");
        if (enemyAir < Global::RoleSettings::Air::EscortMinEnemyAirCost) return 0;
        // Full ratio once the enemy air investment reaches the full-escort mark.
        const float full = AiMax(Global::RoleSettings::Air::EscortFullEnemyAirCost, 1.0f);
        const float scale = AiMin(enemyAir / full, 1.0f);
        return ratio * scale;
    }
    int FightersFor(int bombers)
    {
        if (bombers <= 0) return 0;
        const float want = float(bombers) * EscortRatio();
        int n = int(want);
        if (float(n) < want) ++n;
        return n;
    }

    /**************************************************************************
     Military::AiMakeTask entry. Returns null for units the wave system does
     not manage; the caller then takes the native default task.
     **************************************************************************/
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!IsEnabled() || u is null || u.circuitDef is null) return null;
        const bool isBomber = IsWaveBomber(u.circuitDef);
        const bool isFighter = !isBomber && IsWaveFighter(u.circuitDef);
        if (!isBomber && !isFighter) return null;

        const string key = "" + u.id;
        if (launchQueue.exists(key)) {
            launchQueue.delete(key);
            if (ai.frame <= releaseUntilFrame) {
                IUnitTask@ t = isBomber ? _MakeWaveTaskFor(u) : _MakeEscortTask(u);
                if (t !is null) return t;
            }
            // Missed the window or nothing to join: park it for the next wave.
        }
        else if (isFighter && waveFighters.exists(key)) {
            // Escort whose bomber died while the wave still has living bombers.
            IUnitTask@ t = _MakeEscortTask(u);
            if (t !is null) return t;
            waveFighters.delete(key);
        }
        else if (isBomber && waveBombers.exists(key)) {
            if (mopUp.exists(key)) {
                // The planned run is over (CAirWaveTask aborted itself): one
                // native bomb task to finish what the carpet left, then home.
                mopUp.delete(key);
                IUnitTask@ t = _MakeWaveBombTask(u);
                if (t !is null) return t;
            }
            // Wave bomber back from its run (bomb task aborted or merged away): the
            // wave is over for this unit, it rejoins the pool.
            waveBombers.delete(key);
        }
        return _MakeHoldTask(u, isBomber);
    }

    /**************************************************************************
     Sizing floor from income (D-045).
     **************************************************************************/
    int IncomeFloor()
    {
        const float step = Global::RoleSettings::Air::BomberWaveIncomeStep;
        if (step <= 0.0f) return 0;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        return int(mi / step) * Global::RoleSettings::Air::BomberWaveSizePerIncomeStep;
    }

    // What the next wave must hold: the survival-grown target or the income floor.
    bool OpeningDone() { return aiTerrainMgr.GetLayoutInt("air.openingBombDone", 0) != 0; }
    int OpeningSize()
    {
        int size = aiTerrainMgr.GetLayoutInt("air.firstBomberSize", 0);
        if (size <= 0) {
            const int lo = AirMath::OpeningWave(Global::RoleSettings::Air::FirstBomberWaveMin,
                Global::RoleSettings::Air::FirstBomberWaveMax, 0);
            const int hi = AirMath::OpeningWave(Global::RoleSettings::Air::FirstBomberWaveMin,
                Global::RoleSettings::Air::FirstBomberWaveMax, 300);
            size = AiRandom(lo, hi);
            aiTerrainMgr.SetLayoutInt("air.firstBomberSize", size);
            GenericHelpers::LogUtil("[AIR][Waves] opening size drawn=" + size, 1);
        }
        return size;
    }
    int Required()
    {
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            if (!OpeningDone()) return OpeningSize();
            return AiMin(Global::RoleSettings::Air::StrikeWaveCap,
                AiMax(Global::RoleSettings::Air::StrikeFirstSize, targetMinimum));
        }
        const int floor = IncomeFloor();
        int req = (nextWaveSize > floor) ? nextWaveSize : floor;
        const int hi = Global::RoleSettings::Air::BomberWaveMaxSize;
        return (req > hi) ? hi : req;
    }

    // Maintain a funded replacement pool independently of the next sortie's
    // target-specific size. Extra factories must not stop after eight bombers.
    int ProductionTarget()
    {
        if (!Global::RoleSettings::Air::ExperimentalBuild) return Required();
        CCircuitDef@ d = ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side));
        if (d is null) return Required();
        float rate = 0.0f;
        for (uint b = 0; b < AirEconomy::power.length(); ++b)
            if (UnitHelpers::IsT2AircraftPlant(AirLayout::bays[b].defName))
                rate += ProductionMath::Rate(d.GetBuildTime(), AirEconomy::power[b], Global::RoleSettings::Air::WarmFactoryGapSeconds);
        const int reserve = AirMath::WaveTarget(1, Global::RoleSettings::Air::StrikeFirstSize,
            Global::RoleSettings::Air::StrikeWaveCap, Global::RoleSettings::Air::StrikeWaveCap, 0,
            Global::RoleSettings::Air::StrikeReserveSeconds, rate,
            AirEconomy::metal * Global::RoleSettings::Air::StrikeBudgetShare,
            AirEconomy::energy * Global::RoleSettings::Air::StrikeBudgetShare, d.costM, d.costE);
        return AiMax(Required(), reserve);
    }

    /**************************************************************************
     Attack methods (doc/air-wave-attacks.md).
     **************************************************************************/
    int _ChooseMethod()
    {
        array<float> w = {
            Global::RoleSettings::Air::WaveWeightCarpet, Global::RoleSettings::Air::WaveWeightFlank,
            Global::RoleSettings::Air::WaveWeightPincer, Global::RoleSettings::Air::WaveWeightStrike,
            Global::RoleSettings::Air::WaveWeightDeep, Global::RoleSettings::Air::WaveWeightFeint };
        float sum = 0.0f;
        for (uint i = 0; i < w.length(); ++i) { if (w[i] > 0.0f) sum += w[i]; }
        if (sum <= 0.0f) return Task::WaveMode::CARPET;
        const float roll = (float(AiRandom(0, 999)) + 0.5f) / 1000.0f * sum;
        float acc = 0.0f;
        for (uint i = 0; i < w.length(); ++i) {
            if (w[i] <= 0.0f) continue;
            acc += w[i];
            if (roll < acc) return int(i);
        }
        return Task::WaveMode::CARPET;
    }

    string MethodName(int m)
    {
        if (m == Task::WaveMode::CARPET) return "CARPET";
        if (m == Task::WaveMode::FLANK) return "FLANK";
        if (m == Task::WaveMode::PINCER) return "PINCER";
        if (m == Task::WaveMode::STRIKE) return "STRIKE";
        if (m == Task::WaveMode::DEEP) return "DEEP";
        if (m == Task::WaveMode::FEINT) return "FEINT";
        return "?";
    }

    // The point a carpet runs through: the current combat focus, else the
    // middle of the map.
    AIFloat3 _FrontAim()
    {
        AIFloat3 p = aiMilitaryMgr.GetCombatFocusPos();
        // With no ground front, an AIR duel can focus on interceptors over our
        // own runway. A bomber sortie should instead survey an actual enemy
        // start; this uses participating starts, not every unused map slot.
        if (Global::RoleSettings::Air::ExperimentalBuild && Global::RoleSettings::Air::WaveAvoidHomeFocus
            && (Military::GetEnemySurfaceCostPerPlayer() <= 0.0f || p.x < 0.0f || p.z < 0.0f || MapHelpers::SqDist(p, Global::Map::StartPos)
                < Global::RoleSettings::Air::AllyRange * Global::RoleSettings::Air::AllyRange)) {
            array<AIFloat3> starts = Lanes::ScriptStarts(true);
            float best = 1.0e12f;
            for (uint i = 0; i < starts.length(); ++i) {
                const float dist = MapHelpers::SqDist(starts[i], Global::Map::StartPos);
                if (dist < best && dist > Global::RoleSettings::Air::AllyRange * Global::RoleSettings::Air::AllyRange) {
                    p = starts[i]; best = dist;
                }
            }
            if (best < 1.0e12f) GenericHelpers::LogUtil("[AIR][Waves] home focus replaced by enemy start " + int(p.x) + "," + int(p.z), 1);
        }
        if (p.x < 0.0f || p.z < 0.0f) {
            p = AIFloat3(float(AiTerrainWidth()) * 0.5f, 0.0f, float(AiTerrainHeight()) * 0.5f);
        }
        return p;
    }

    // Build the launched wave's plan. Null when the native task could not be
    // made; the launch then uses the plain bomb tasks.
    void ConfigureStrike(CAirWaveTask@ wt, CCircuitDef@ first, const dictionary &in roster, int count = -1)
    {
        wt.SetFlightPolicy(Global::RoleSettings::Air::StrikeFormationWidth,
            Global::RoleSettings::Air::StrikeRankSpacing, Global::RoleSettings::Air::StrikeLossAbort, Global::Map::StartPos);
        wt.SetAssemblyPolicy(Global::RoleSettings::Air::StrikeAssemblyRadius,
            Global::RoleSettings::Air::StrikeAssemblyFraction, Global::RoleSettings::Air::StrikeJoinSeconds * SECOND);
        wt.SetStrikePolicy(first, count < 0 ? int(roster.getSize()) : count, Global::RoleSettings::Air::StrikePassFraction,
            Global::RoleSettings::Air::StrikeDamageMargin, Global::RoleSettings::Air::StrikeThreatWeight,
            Global::RoleSettings::Air::StrikeMaxThreat);
        array<string>@ ids = roster.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ member = ai.GetTeamUnit(parseInt(ids[i]));
            if (member !is null) wt.ConsiderStrikeAircraft(ai.GetCircuitDef(member.circuitDef.GetName()));
        }
    }

    IUnitTask@ _PlanWave(int bombers)
    {
        IUnitTask@ raw = aiMilitaryMgr.Enqueue(TaskF::Wave());
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CAirWaveTask@ wt = (ft is null) ? null : cast<CAirWaveTask>(ft);
        if (wt is null) {
            GenericHelpers::LogUtil("[AIR][Waves] no CAirWaveTask; wave " + waveIndex + " flies the plain bomb task", 1);
            return null;
        }
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            ConfigureStrike(wt, ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side)), heldBombers, bombers);
            wt.SetMissionPolicy(Global::RoleSettings::Air::StrikeCorridorPadding,
                Global::RoleSettings::Air::StrikeEdgeInset, Global::RoleSettings::Air::StrikeUnknownReserve + learnedResistance - 1.0f,
                Global::RoleSettings::Air::StrikeRiskScale * learnedResistance, Global::RoleSettings::Air::StrikeArmyReserve * learnedResistance,
                Global::RoleSettings::Air::StrikeLocalAaReserve * learnedResistance,
                Global::RoleSettings::Air::StrikeSynchronize);
            for (int i = int(failedRaidUntil.length()) - 1; i >= 0; --i) {
                if (ai.frame >= failedRaidUntil[i]) {
                    failedRaidUntil.removeAt(i); failedRaidAims.removeAt(i);
                } else wt.ExcludeStrikeRegion(failedRaidAims[i], Global::RoleSettings::Air::StrikeFailedRegionRadius);
            }
            // Defend a nearby T3 first; otherwise seek reachable backline economy.
            // Frontline static is the fallback when no backline target qualifies.
            AirOperations::Configure(wt, false, 6);
            plannedDefensive = wt.PickStrikeTarget(Global::Map::StartPos, 6, 0.0f, true);
            const int defensiveMinimum = wt.GetRequiredBombers();
            // Accumulate a viable response before committing to cheap cleanup.
            // This only governs launch; an existing offensive wave stays committed.
            if (!plannedDefensive && defensiveMinimum > bombers) {
                targetMinimum = defensiveMinimum;
                HoldReason("defensive payload", bombers, defensiveMinimum);
                raw.Abort();
                return null;
            }
            if (!plannedDefensive) {
                AirOperations::Configure(wt, true, 5);
                // The opening draw sizes an economy raid. A blocked backline
                // must still allow a larger, payload-funded frontline assault.
                if (!OpeningDone()) ConfigureStrike(wt,
                    ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side)),
                    heldBombers, AiMin(bombers, OpeningSize()));
            }
            const int preference = 5;
            // Supply the ground-front objective before selecting the actual target.
            wt.SetPlan(Task::WaveMode::STRIKE, plannedDefensive ? wt.GetAim() : _FrontAim(), Global::RoleSettings::Air::WaveFormDistance,
                Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun,
                Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND, 0, Task::WAVE_SMART_BEARING, 1);
            plannedFront = !plannedDefensive && !wt.PickStrikeTarget(Global::Map::StartPos, preference,
                Global::RoleSettings::Air::StrikeMinTargetMetal, false);
            if (plannedFront) ConfigureStrike(wt,
                ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side)), heldBombers, bombers);
            if (plannedFront && !wt.PickOperationTarget(Global::Map::StartPos, 0.0f, false)) {
                targetMinimum = wt.GetRequiredBombers();
                raw.Abort();
                if (ai.frame - lastNoTargetLog >= 30 * SECOND) {
                    lastNoTargetLog = ai.frame;
                    GenericHelpers::LogUtil("[AIR][Waves] held: no feasible known target; defensive minimum="
                        + defensiveMinimum + " available=" + bombers + "; request fresh reconnaissance", 1);
                }
                return null;
            }
            targetMinimum = wt.GetRequiredBombers();
            for (uint i = 0; i < failedRaidAims.length(); ++i)
                if (MapHelpers::SqDist(wt.GetAim(), failedRaidAims[i]) <= Global::RoleSettings::Air::StrikeFailedRegionRadius
                    * Global::RoleSettings::Air::StrikeFailedRegionRadius)
                    Invariants::Violation("INV-105", "failed.raid", "AIR selected a target in an unexpired failed raid region");
            plannedCount = AirMath::OperationSize(bombers, targetMinimum, OpeningDone(), OpeningSize(),
                plannedFront, plannedDefensive, Global::RoleSettings::Air::StrikeFirstSize);
            if (plannedCount == 0 || FightersFor(plannedCount) > int(AirOperations::AvailableFighters())) {
                HoldReason(plannedCount == 0 ? "target/opening budget" : "escort budget", bombers, targetMinimum);
                raw.Abort(); return null;
            }
            ConfigureStrike(wt, ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side)), heldBombers, plannedCount);
            wt.SetPlan(Task::WaveMode::STRIKE, wt.GetAim(), Global::RoleSettings::Air::WaveFormDistance,
                Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun, Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND,
                0, Task::WAVE_SMART_BEARING, 1);
            lastMethod = Task::WaveMode::STRIKE;
            lastRaidAim = wt.GetAim();
            GenericHelpers::LogUtil("[AIR][Waves] planned strike target=" + wt.GetStrikeTargetId()
                + " bombers=" + plannedCount + " required=" + targetMinimum + " aim=" + int(wt.GetAim().x) + "," + int(wt.GetAim().z)
                + " mission=" + (plannedDefensive ? "defensive" : plannedFront ? "frontline" : "economy"), 1);
            return raw;
        }
        const float fd = Global::RoleSettings::Air::WaveFormDistance;
        const float sp = Global::RoleSettings::Air::WaveLaneSpacing;
        const float ov = Global::RoleSettings::Air::WaveOverrun;
        const int ft0 = Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND;
        const float minCost = Global::RoleSettings::Air::WaveStrikeMinStaticCost;
        int method = _ChooseMethod();
        AIFloat3 aim = _FrontAim();
        string detail = "";
        if (method == Task::WaveMode::STRIKE || method == Task::WaveMode::DEEP) {
            const int pref = (method == Task::WaveMode::DEEP) ? 1 : 0;
            if (wt.PickStrikeTarget(Global::Map::StartPos, pref, minCost, true)) {
                aim = wt.GetAim();
                detail = " target=" + wt.GetStrikeTargetId();
            } else {
                GenericHelpers::LogUtil("[AIR][Waves] " + MethodName(method) + ": no qualifying target (statics >= "
                    + int(minCost) + " or T3); carpeting the front instead", 1);
                method = Task::WaveMode::CARPET;
            }
        }
        if (method == Task::WaveMode::CARPET) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, 0.0f, 1);
        } else if (method == Task::WaveMode::FLANK) {
            const float lo = Global::RoleSettings::Air::WaveFlankMinDeg;
            const float hi = Global::RoleSettings::Air::WaveFlankMaxDeg;
            float deg = lo + (hi - lo) * float(AiRandom(0, 999)) / 999.0f;
            if (AiRandom(0, 1) == 1) deg = -deg;
            detail = " bearing=" + int(deg);
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, deg, 1);
        } else if (method == Task::WaveMode::PINCER) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, Global::RoleSettings::Air::WavePincerDeg, 2);
        } else if (method == Task::WaveMode::STRIKE || method == Task::WaveMode::DEEP) {
            wt.SetPlan(method, aim, fd, sp, ov, ft0, 0, Task::WAVE_SMART_BEARING, 1);
        } else {  // FEINT
            wt.SetPlan(method, aim, fd, sp, ov, ft0, Global::RoleSettings::Air::WaveFeintHoldSeconds * SECOND, 0.0f, 1);
        }
        lastMethod = method;
        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " method=" + MethodName(method)
            + " aim=(" + int(aim.x) + "," + int(aim.z) + ")" + detail + " bombers=" + bombers
            + " standoff=" + int(fd) + " spacing=" + int(sp), 1);
        return raw;
    }

    IUnitTask@ StagingTask(CCircuitUnit@ u, bool isBomber)
    {
            CRouteTask@ route = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            if (route is null) return null;
            const int slot = u.id % 49;
            AIFloat3 pos = Global::Map::StartPos;
            pos.x = AiMax(160.0f, AiMin(float(AiTerrainWidth()) - 160.0f, pos.x + float(slot % 7 - 3) * 96.0f));
            pos.z = AiMax(160.0f, AiMin(float(AiTerrainHeight()) - 160.0f, pos.z + float(slot / 7 - 3) * 96.0f));
            array<AIFloat3> points = { pos };
            if (!isBomber) {
                points.insertLast(AIFloat3(pos.x + 80.0f, 0.0f, pos.z));
                route.SetPatrol(true);
            }
            route.SetAirControl(true);
            route.SetRoute(points);
            route.SetTraversal(true, 192.0f, false);
            u.SetIdleMode(isBomber ? 1 : 0);
            u.SetFireState(isBomber ? 0 : 2);
            return route;
    }
    IUnitTask@ _MakeHoldTask(CCircuitUnit@ u, bool isBomber)
    {
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            IUnitTask@ stage = StagingTask(u, isBomber);
            if (stage is null) return null;
            dictionary@ pool = isBomber ? @heldBombers : @heldFighters;
            pool.set("" + u.id, int(u.id));
            if (isBomber && holdSinceFrame < 0) holdSinceFrame = ai.frame;
            return stage;
        }
        // Distinct promote types keep bomber and fighter holds from merging into
        // each other or into native riot holds (promote ATTACK). See header.
        const Task::FightType promote = isBomber ? Task::FightType::BOMB : Task::FightType::AA;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Defend(Task::FightType::MELEE, promote, HoldPower));
        if (t is null) return null;
        dictionary@ held = isBomber ? @heldBombers : @heldFighters;
        held.set("" + u.id, int(u.id));
        if (isBomber && holdSinceFrame < 0) holdSinceFrame = ai.frame;
        return t;
    }

    IUnitTask@ _MakeWaveTaskFor(CCircuitUnit@ u)
    {
        if (waveTask !is null) return waveTask;
        return _MakeWaveBombTask(u);
    }

    IUnitTask@ _MakeWaveBombTask(CCircuitUnit@ u)
    {
        const string defName = u.circuitDef.GetName();
        IUnitTask@ t = null;
        if (!waveBombTasks.get(defName, @t) || t is null) {
            @t = aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::BOMB));
            if (t is null) return null;
            waveBombTasks.set(defName, @t);
        }
        return t;
    }

    // Guard the next living wave bomber (round-robin). CFGuardTask is deduplicated
    // per vip by CMilitaryManager::Enqueue, so fighters on the same bomber share
    // one task; the script assignment path does not apply the native guard cap.
    IUnitTask@ _MakeEscortTask(CCircuitUnit@ u)
    {
        array<string>@ vips = waveBombers.getKeys();
        for (uint tries = 0; tries < vips.length(); ++tries) {
            const string vipKey = vips[nextVipIdx++ % vips.length()];
            int vipId = 0;
            if (!waveBombers.get(vipKey, vipId)) continue;
            CCircuitUnit@ vip = ai.GetTeamUnit(vipId);
            if (vip is null) { waveBombers.delete(vipKey); continue; }
            IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Guard(vip));
            if (t is null) continue;
            waveFighters.set("" + u.id, int(u.id));
            return t;
        }
        return null;
    }

    /**************************************************************************
     Main update (Air_MainUpdate, every 30 frames).
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        const int frame = ai.frame;
        if (releaseUntilFrame >= 0 && frame > releaseUntilFrame) _EndRelease();
        if (!lastWaveEvaluated && lastLaunchFrame >= 0
            && (!Global::RoleSettings::Air::ExperimentalBuild || waveTask is null || waveTask.IsDead())
            && frame >= lastLaunchFrame + Global::RoleSettings::Air::BomberWaveEvaluateSeconds * SECOND) {
            _EvaluateLastWave();
        }
        if (releaseUntilFrame < 0) _TryLaunch(frame);
    }

    void HoldReason(const string &in reason, int available, int required)
    {
        // Diagnostics only: no command throttle or additional target scan.
        if (ai.frame-lastNoTargetLog < 30*SECOND) return;
        lastNoTargetLog = ai.frame;
        GenericHelpers::LogUtil("[AIR][Waves] held: " + reason + " available=" + available
            + " required=" + required + " baseContact=" + AirBaseResponse::Emergency(), 1);
    }

    void _TryLaunch(int frame)
    {
        // D-227: base response already owns aircraft assigned to a real
        // defense target. An incompatible contact cannot veto spare bombers.
        const int bombers = int(heldBombers.getSize());
        const int fighters = Global::RoleSettings::Air::ExperimentalBuild ? int(AirOperations::AvailableFighters()) : int(heldFighters.getSize());
        if (bombers == 0) { holdSinceFrame = -1; return; }
        if (holdSinceFrame < 0) holdSinceFrame = frame;
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            // One surviving committed bomber must not lock out every later
            // cohort. The old operation/escorts retain their task in
            // AirOperations; cadence only spaces additional fresh operations.
            const bool busy = waveTask !is null && !waveTask.IsDead()
                && frame-lastLaunchFrame < AiMax(1, Global::RoleSettings::Air::StrikeCadenceSeconds)*SECOND;
            if (busy) { HoldReason("strike cadence", bombers, targetMinimum); return; }
            if (frame - lastPlanFrame < 10 * SECOND) return;
            const int floor = 3; // A small defensive T3 response may launch before the offensive draw.
            if (bombers < floor || fighters < FightersFor(floor)) {
                HoldReason(bombers < floor ? "bomber floor" : "escort floor", bombers, floor); return;
            }
            lastPlanFrame = frame;
            // Re-probe even below an old target minimum: reconnaissance may
            // expose a cheaper objective. Never waive the new target's budget.
            _Launch(frame, "target and route budget", AiMin(bombers, Global::RoleSettings::Air::StrikeWaveCap));
            return;
        }

        const int minSize = Global::RoleSettings::Air::BomberWaveFirstSize;
        const int required = Required();
        const bool targetReached = (bombers >= required) && (fighters >= FightersFor(required));
        // The time-out waives the escort requirement only: a side that cannot
        // field fighters must still launch with whatever escort it has. The
        // bomber floor stands - at high income a five-bomber wave was launching
        // against a floor of fifty (CR-013).
        const bool timedOut = (bombers >= minSize) && (bombers >= required)
            && (frame - holdSinceFrame) >= Global::RoleSettings::Air::BomberWaveMaxHoldSeconds * SECOND;
        if (!targetReached && !timedOut) return;
        _Launch(frame, targetReached ? ("target " + required + " reached (income floor " + IncomeFloor() + ")")
                                     : ("hold time-out at " + bombers + "/" + required));
    }

    void _Launch(int frame, const string &in reason, int limit = -1)
    {
        IUnitTask@ planned = null;
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            @planned = _PlanWave(limit < 0 ? int(heldBombers.getSize()) : limit);
            if (planned is null) return;
            limit = plannedCount;
        }
        waveBombers.deleteAll();
        waveFighters.deleteAll();
        waveBombTasks.deleteAll();
        launchQueue.deleteAll();
        mopUp.deleteAll();
        @waveTask = null;
        nextVipIdx = 0;

        array<IUnitTask@> aborted;
        int attached = 0;
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            array<string>@ ids = heldBombers.getKeys();
            for (uint i = 0; i < ids.length() && int(waveBombers.getSize()) < limit; ++i) {
                CCircuitUnit@ member = ai.GetTeamUnit(parseInt(ids[i]));
                if (member is null) { heldBombers.delete(ids[i]); continue; }
                if (aiMilitaryMgr.TransferUnit(member, planned)) {
                    waveBombers.set(ids[i], int(member.id)); heldBombers.delete(ids[i]);
                }
            }
            attached = AirOperations::AttachFighters(cast<CAirWaveTask>(planned), !plannedDefensive);
            AirOperations::TrackBombers(planned, waveBombers);
        } else {
            _ReleaseHeld(@heldBombers, @waveBombers, @aborted, limit);
            _ReleaseHeld(@heldFighters, null, @aborted, limit < 0 ? -1 : FightersFor(limit));
        }
        const int launchedBombers = int(waveBombers.getSize());
        const int launchedFighters = Global::RoleSettings::Air::ExperimentalBuild ? attached : int(launchQueue.getSize()) - launchedBombers;
        if (Global::RoleSettings::Air::ExperimentalBuild
            && ((!plannedDefensive && !plannedFront && !OpeningDone() && launchedBombers != OpeningSize()) || launchedBombers < targetMinimum))
            Invariants::Violation("INV-103", "" + waveIndex, "bomber release differs from opening draw or cannot fund selected mission");

        ++waveIndex;
        if (Global::RoleSettings::Air::ExperimentalBuild && launchedBombers > 0 && !plannedDefensive && !plannedFront)
            aiTerrainMgr.SetLayoutInt("air.openingBombDone", 1);
        @waveTask = Global::RoleSettings::Air::ExperimentalBuild ? planned : _PlanWave(launchedBombers);
        evaluationCohort.deleteAll();
        {
            array<string>@ ids = waveBombers.getKeys();
            for (uint i = 0; i < ids.length(); ++i) {
                evaluationCohort.set(ids[i], true);
                if (!Global::RoleSettings::Air::ExperimentalBuild) mopUp.set(ids[i], true);
            }
        }
        lastWaveSize = launchedBombers;
        lastLaunchFighters = launchedFighters;
        lastLaunchFrame = frame;
        lastWaveEvaluated = false;
        releaseUntilFrame = frame + Global::RoleSettings::Air::BomberWaveReleaseWindowSeconds * SECOND;
        holdSinceFrame = -1;
        // Provisional target until the survival ratio is known.
        nextWaveSize = _Clamp(int(float(lastWaveSize) * Global::RoleSettings::Air::BomberWaveGrowthDefault + 0.5f));

        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " launched (" + reason + "): bombers=" + launchedBombers
            + " fighters=" + launchedFighters + " holdTasksAborted=" + aborted.length()
            + " provisionalNext=" + nextWaveSize, 1);
    }

    // Move every held id into the launch queue (and `wave` when given) and abort
    // each distinct hold task once. Only DEFEND fighter tasks are aborted: a unit
    // that is retreating or idle keeps that task and takes its wave task when it
    // next asks for one inside the release window.
    void _ReleaseHeld(dictionary@ held, dictionary@ wave, array<IUnitTask@>@ aborted, int limit = -1)
    {
        array<string>@ keys = held.getKeys();
        int released = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            if (limit >= 0 && released >= limit) break;
            int id = 0;
            if (!held.get(keys[i], id)) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) { held.delete(keys[i]); continue; }
            launchQueue.set(keys[i], id);
            if (wave !is null) wave.set(keys[i], id);
            held.delete(keys[i]);
            ++released;

            IUnitTask@ t = u.task;
            if (t is null || Task::Type(t.GetType()) != Task::Type::FIGHTER) continue;
            IFighterTask@ ft = cast<IFighterTask>(t);
            if (ft is null || (Task::FightType(ft.GetFightType()) != Task::FightType::DEFEND
                && (!Global::RoleSettings::Air::ExperimentalBuild || Task::FightType(ft.GetFightType()) != Task::FightType::ROUTE))) continue;
            if (_ContainsTask(@aborted, t)) continue;
            aborted.insertLast(t);
            t.Abort();
        }
        if (limit < 0) held.deleteAll();
    }

    bool _ContainsTask(array<IUnitTask@>@ list, IUnitTask@ t)
    {
        for (uint i = 0; i < list.length(); ++i) {
            if (list[i] is t) return true;
        }
        return false;
    }

    void _EndRelease()
    {
        const int stragglers = int(launchQueue.getSize());
        launchQueue.deleteAll();
        waveBombTasks.deleteAll();
        releaseUntilFrame = -1;
        if (stragglers > 0) {
            GenericHelpers::LogUtil("[AIR][Waves] Release window closed with " + stragglers
                + " unit(s) never re-tasked; they rejoin the hold when idle", 2);
        }
    }

    void _EvaluateLastWave()
    {
        lastWaveEvaluated = true;
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            // A one-way operation has zero survivors by design. Do not learn
            // a failed route from that alone; each launch remeasures visible AA.
            learnedResistance = 1.0f;
            nextWaveSize = Required();
            GenericHelpers::LogUtil("[AIR][Waves] committed operation ended; next=" + nextWaveSize, 1);
            return;
        }
        int survivors = 0;
        array<string>@ cohort = evaluationCohort.getKeys();
        for (uint i = 0; i < cohort.length(); ++i) if (ai.GetTeamUnit(parseInt(cohort[i])) !is null) ++survivors;
        if (survivors > lastWaveSize) Invariants::Violation("INV-099", "cohort", "AIR survivor count exceeds immutable launch size");
        const float survival = (lastWaveSize > 0) ? float(survivors) / float(lastWaveSize) : 1.0f;
        if (Global::RoleSettings::Air::ExperimentalBuild) {
            learnedResistance = AirMath::RaidResistance(learnedResistance, survival,
                Global::RoleSettings::Air::BomberWaveLowSurvival, Global::RoleSettings::Air::BomberWaveHighSurvival,
                Global::RoleSettings::Air::StrikeLossGrowth, Global::RoleSettings::Air::StrikeRiskRecovery,
                Global::RoleSettings::Air::StrikeLearnedRiskMax);
            aiTerrainMgr.SetLayoutInt("air.raidRiskMilli", int(learnedResistance * 1000.0f));
            if (survival < Global::RoleSettings::Air::StrikeFailedSurvival
                && Global::RoleSettings::Air::StrikeFailedRetrySeconds > 0
                && Global::RoleSettings::Air::StrikeFailedRegionRadius > 0.0f) {
                if (failedRaidAims.length() >= 8) { failedRaidAims.removeAt(0); failedRaidUntil.removeAt(0); }
                failedRaidAims.insertLast(lastRaidAim);
                failedRaidUntil.insertLast(ai.frame + AiMin(3600, Global::RoleSettings::Air::StrikeFailedRetrySeconds) * SECOND);
                GenericHelpers::LogUtil("[AIR][Waves] failed raid excluded aim=" + int(lastRaidAim.x) + "," + int(lastRaidAim.z)
                    + " radius=" + int(Global::RoleSettings::Air::StrikeFailedRegionRadius) + " until=" + failedRaidUntil[failedRaidUntil.length() - 1], 1);
            }
            GenericHelpers::LogUtil("[AIR][Waves] learned resistance=" + learnedResistance + " survival=" + survival, 1);
        }
        const float enemyAAMetal = Military::GetCachedRoleCost("anti_air");
        const float bomberCost = _WaveBomberCost();
        const int previous = nextWaveSize;
        nextWaveSize = Global::RoleSettings::Air::ExperimentalBuild ? Required()
            : ComputeNextWaveSize(lastWaveSize, survival, enemyAAMetal, bomberCost);
        GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + " evaluated: launched=" + lastWaveSize
            + " survivors=" + survivors + " survival=" + survival + " enemyAAMetal=" + enemyAAMetal
            + " bomberCost=" + bomberCost + " next=" + nextWaveSize + " (provisional was " + previous + ")", 1);
    }

    /**************************************************************************
     Sizing. Pure function of the previous wave and the enemy anti-air, so it can
     be reasoned about from the settings alone:
       growth  = survival < Low  ? GrowthOnHeavyLoss
               : survival > High ? GrowthOnLightLoss
               :                   GrowthDefault
       next    = round(previous * growth)
       aaFloor = round(enemyAAMetal * EnemyAAMetalFraction / bomberCost)
       result  = clamp(max(next, aaFloor), FirstSize, MaxSize)
     **************************************************************************/
    int ComputeNextWaveSize(int previous, float survival, float enemyAAMetal, float bomberCost)
    {
        float growth = Global::RoleSettings::Air::BomberWaveGrowthDefault;
        if (survival < Global::RoleSettings::Air::BomberWaveLowSurvival) {
            growth = Global::RoleSettings::Air::BomberWaveGrowthOnHeavyLoss;
        } else if (survival > Global::RoleSettings::Air::BomberWaveHighSurvival) {
            growth = Global::RoleSettings::Air::BomberWaveGrowthOnLightLoss;
        }
        int next = int(float(previous) * growth + 0.5f);
        if (bomberCost > 0.0f && enemyAAMetal > 0.0f) {
            const int aaFloor = int(enemyAAMetal * Global::RoleSettings::Air::BomberWaveEnemyAAMetalFraction / bomberCost + 0.5f);
            if (next < aaFloor) next = aaFloor;
        }
        return _Clamp(next);
    }

    int _Clamp(int size)
    {
        const int lo = Global::RoleSettings::Air::BomberWaveFirstSize;
        const int hi = Global::RoleSettings::Air::BomberWaveMaxSize;
        if (size < lo) size = lo;
        if (size > hi) size = hi;
        return size;
    }

    float _WaveBomberCost()
    {
        const string name = UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side);
        CCircuitDef@ d = (name.length() == 0) ? null : ai.GetCircuitDef(name);
        return (d is null) ? 0.0f : d.costM;
    }

    /**************************************************************************
     Production: called by the AIR factory handler for a T2 aircraft plant. One
     recruit per call; the factory asks again when idle. Bombers and fighters are
     grown together so the escort is ready when the bombers are.
     **************************************************************************/
    IUnitTask@ MakeProductionTask(CCircuitUnit@ factory, const string &in side, const AIFloat3 &in pos)
    {
        if (!IsEnabled() || factory is null) return null;
        if (Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Air::BomberWaveProductionMetalIncome) return null;

        const int bombers = int(heldBombers.getSize());
        const int fighters = Global::RoleSettings::Air::ExperimentalBuild ? int(AirProduction::home.getSize()) : int(heldFighters.getSize());
        const int required = Required();
        const int targetFighters = FightersFor(required);

        string name = "";
        if (fighters < FightersFor(bombers) && fighters < targetFighters) {
            name = UnitHelpers::GetT2FighterForSide(side);      // escort lags the bombers
        } else if (bombers < required) {
            name = UnitHelpers::GetT2WaveBomberForSide(side);
        } else if (fighters < targetFighters) {
            name = UnitHelpers::GetT2FighterForSide(side);
        }
        if (name.length() == 0) return null;

        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        GenericHelpers::LogUtil("[AIR][Waves] Production: " + name + " (held bombers=" + bombers
            + "/" + required + " fighters=" + fighters + "/" + targetFighters + ")", 3);
        return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d, pos, 64.f));
    }

    /**************************************************************************
     Bookkeeping hooks.
     **************************************************************************/
    void OnUnitRemoved(CCircuitUnit@ u)
    {
        if (u is null) return;
        const string key = "" + u.id;
        heldBombers.delete(key);
        heldFighters.delete(key);
        launchQueue.delete(key);
        waveBombers.delete(key);
        waveFighters.delete(key);
    }

    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task is null) return;
        if (waveTask !is null && waveTask is task) {
            @waveTask = null;
            GenericHelpers::LogUtil("[AIR][Waves] Wave " + waveIndex + (Global::RoleSettings::Air::ExperimentalBuild
                ? (plannedDefensive ? " defensive operation complete; survivors repair/stage" : " committed operation exhausted") : " run over; survivors mop up on the native bomb task"), 1);
        }
        if (waveBombTasks.getSize() == 0) return;
        array<string>@ keys = waveBombTasks.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            IUnitTask@ t = null;
            if (waveBombTasks.get(keys[i], @t) && t is task) {
                waveBombTasks.delete(keys[i]);
            }
        }
    }
}  // namespace AirWaves
