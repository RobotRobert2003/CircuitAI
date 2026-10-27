#include "../../global.as"
#include "../../systems/air/air_liches.as"

/******************************************************************************

CAPITAL RUSH (owner, 2026-10-26; Strategy::CAPITAL_RUSH, plan "capitalrush")

The T2 aircraft plant builds the side's capital ship: Liche (armliche),
Dragon (corcrwh) or Tyrannus (legfort) (CapitalRushUnits), and
CapitalRushFightersPerShip (2) T2 fighters (Hawk, Vamp, Venator) for each.

Gate: the 10 s minimum metal income reaches CapitalRushMetalIncome (150) and
the plant has its dedicated constructors (D-108, filled ahead of this in
Tech_FactoryAiMakeTask). From then on the plant builds nothing but ships and
their fighters while a batch is owed: CapitalRushFirstBatch (5) ships, then
CapitalRushNextBatch (10) more for every CapitalRushMetalStep (100) of income
above the gate, reached once (one-way: a dip cancels nothing). Ships and
fighters alternate (ship, its fighters, next ship). Between batches the
plant's ordinary production resumes.

Everything finished is held at home (AirWaves::StagingTask). When the batch's
ships and fighters are all done it is one wave (owner, 2026-10-27: no trades
to AIR any more):
  - Liches join one native CEscortStrikeTask in siege mode
    (EscortStrikeTask.h): AIR's Liche roster (AirLiches::InitRoster, shields
    first), CapitalRushLichesPerTarget on each scouted target anywhere, the
    unit while in sight, else ATTACK ground on its last known spot (as a
    Juno), kept until it no longer exists; with no target left, home;
  - Dragons and Tyrannus go to native attack (DefaultMakeTask);
  - each ship gets its fighters in one CEscortStrikeTask in fighter mode:
    they guard it (one GUARD each), fire at will, and go home when it dies.

Cost: the factory hook is O(1) per factory ask; Tick runs once a second over
the held batch only (at most 3 x CapitalRushNextBatch units). Orders: one
staging route per unit, one transfer per unit per wave.

******************************************************************************/
namespace TechCapitalRush {
    const string StateKey = "tech.capital.";
    int built = 0;         // ships finished, every batch together
    int fighters = 0;      // escort fighters finished, every batch together
    int steps = 0;         // batches unlocked by income (one-way)
    int waves = 0;         // batches sent
    int nextTick = 0;
    int nextTrace = 0;
    int originalCap = -1;
    int originalFighterCap = -1;
    IUnitTask@ recruit;    // the one ship or fighter order in flight
    array<int> held;       // finished ships of the batch in progress, staged at home
    array<int> heldFighters;
    dictionary staging;    // unit id -> its staging route task

    bool Selected()
    {
        return Global::AISettings::Role == AiRole::TECH
            && Global::RoleSettings::Tech::CapitalRushEnabled
            && Global::RoleSettings::Tech::HasStrategy(Strategy::CAPITAL_RUSH);
    }
    string UnitName()
    {
        string name;
        if (!Global::RoleSettings::Tech::CapitalRushUnits.get(Global::AISettings::Side, name)) return "";
        return name;
    }
    string FighterName() { return UnitHelpers::GetT2FighterForSide(Global::AISettings::Side); }
    int PerShip() { return AiMax(0, Global::RoleSettings::Tech::CapitalRushFightersPerShip); }
    bool IsCapital(CCircuitUnit@ u) { return u !is null && u.circuitDef !is null && u.circuitDef.GetName() == UnitName(); }
    bool IsFighter(CCircuitUnit@ u) { return u !is null && u.circuitDef !is null && u.circuitDef.GetName() == FighterName(); }

    void Init()
    {
        built = aiTerrainMgr.GetLayoutInt(StateKey + "built", 0);
        fighters = aiTerrainMgr.GetLayoutInt(StateKey + "fighters", 0);
        steps = aiTerrainMgr.GetLayoutInt(StateKey + "steps", 0);
        waves = aiTerrainMgr.GetLayoutInt(StateKey + "waves", 0);
        @recruit = null;
        held.resize(0); heldFighters.resize(0); staging.deleteAll();
        if (!Selected()) return;
        CCircuitDef@ d = ai.GetCircuitDef(UnitName());
        originalCap = (d is null) ? -1 : d.maxThisUnit;
        CCircuitDef@ f = ai.GetCircuitDef(FighterName());
        originalFighterCap = (f is null) ? -1 : f.maxThisUnit;
        GenericHelpers::LogUtil("[TECH][Capital] selected: " + UnitName() + " + " + PerShip() + " " + FighterName() + " each, from +"
            + int(Global::RoleSettings::Tech::CapitalRushMetalIncome) + " metal, " + Global::RoleSettings::Tech::CapitalRushFirstBatch
            + " then " + Global::RoleSettings::Tech::CapitalRushNextBatch + " per +" + int(Global::RoleSettings::Tech::CapitalRushMetalStep), 1);
    }

    // Ships owed by the end of batch k (1-based).
    int BatchEnd(int k)
    {
        if (k <= 0) return 0;
        return Global::RoleSettings::Tech::CapitalRushFirstBatch + Global::RoleSettings::Tech::CapitalRushNextBatch * (k - 1);
    }
    int Owed() { return BatchEnd(steps); }

    void UpdateSteps()
    {
        if (!Economy::IncomeWindowReady()) return;
        const float income = Economy::GetMinMetalIncomeLast10s();
        const float gate = Global::RoleSettings::Tech::CapitalRushMetalIncome;
        if (income < gate) return;
        const float step = AiMax(1.0f, Global::RoleSettings::Tech::CapitalRushMetalStep);
        const int want = 1 + int((income - gate) / step);
        if (want <= steps) return;
        steps = want;
        aiTerrainMgr.SetLayoutInt(StateKey + "steps", steps);
        GenericHelpers::LogUtil("[TECH][Capital] income +" + int(income) + ": batch " + steps + " unlocked, " + Owed() + " ships owed in all ("
            + built + " built, " + fighters + " fighters)", 1);
    }

    void RestoreCaps()
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitName());
        if (d !is null && originalCap >= 0 && d.maxThisUnit != originalCap) d.maxThisUnit = originalCap;
        CCircuitDef@ f = ai.GetCircuitDef(FighterName());
        if (f !is null && originalFighterCap >= 0 && f.maxThisUnit != originalFighterCap) f.maxThisUnit = originalFighterCap;
    }

    void Blocked(const string &in reason)
    {
        if (ai.frame < nextTrace) return;
        nextTrace = ai.frame + 30 * SECOND;
        GenericHelpers::LogUtil("[TECH][Capital] waiting: " + reason + " (built " + built + " of " + Owed() + ")", 1);
    }

    /**************************************************************************
     Production (Tech_FactoryAiMakeTask, after the D-108 air constructors).
     A ship, then its fighters, then the next ship; the batch's last fighters
     follow its last ship.
     **************************************************************************/
    IUnitTask@ Produce(CCircuitUnit@ factory, const string &in side)
    {
        if (!Selected() || factory is null || factory.circuitDef is null
            || factory.circuitDef.GetName() != UnitHelpers::GetT2AirPlantForSide(side)) return null;
        UpdateSteps();
        const int owed = Owed();
        if (built >= owed && fighters >= PerShip() * owed) { RestoreCaps(); return null; }   // between batches: ordinary production
        if (recruit !is null && !recruit.IsDead()) return recruit;
        CCircuitDef@ ship = ai.GetCircuitDef(UnitName());
        CCircuitDef@ fighter = ai.GetCircuitDef(FighterName());
        if (ship is null || !factory.circuitDef.CanBuild(ship)) { Blocked("no " + UnitName() + " at " + factory.circuitDef.GetName()); return null; }
        if (aiFactoryMgr.GetPendingRecruitCount(ship) > 0
            || (fighter !is null && aiFactoryMgr.GetPendingRecruitCount(fighter) > 0)) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        const bool wantFighter = fighter !is null && factory.circuitDef.CanBuild(fighter)
            && (fighters < PerShip() * built || built >= owed);
        CCircuitDef@ d = wantFighter ? fighter : ship;
        if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;   // TECH's start caps may hold it at 0
        if (!d.IsAvailable(ai.frame)) { Blocked(d.GetName() + " not available"); return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND)); }
        @recruit = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, factory.GetPos(ai.frame), 64.f));
        if (recruit !is null)
            GenericHelpers::LogUtil("[TECH][Capital] recruit " + d.GetName() + (wantFighter ? " fighter " + (fighters + 1) + " of " + (PerShip() * owed)
                : " number=" + (built + 1) + " of " + owed) + " (batch " + steps + ") at " + factory.circuitDef.GetName() + " " + factory.id, 1);
        return recruit;
    }

    /**************************************************************************
     Finished (Tech_MilitaryAiUnitAdded) and hold (Military::AiMakeTask).
     **************************************************************************/
    bool OnFinished(CCircuitUnit@ u)
    {
        if (!Selected() || u is null || u.GetBuildProgress() < 1.0f) return false;
        if (IsCapital(u)) {
            if (held.find(u.id) >= 0) return true;
            ++built;
            aiTerrainMgr.SetLayoutInt(StateKey + "built", built);
            held.insertLast(u.id);
        } else if (IsFighter(u) && fighters < PerShip() * Owed()) {
            if (heldFighters.find(u.id) >= 0) return true;
            ++fighters;
            aiTerrainMgr.SetLayoutInt(StateKey + "fighters", fighters);
            heldFighters.insertLast(u.id);
        } else {
            return false;
        }
        @recruit = null;
        if (built >= Owed() && fighters >= PerShip() * Owed()) RestoreCaps();
        GenericHelpers::LogUtil("[TECH][Capital] finished " + u.circuitDef.GetName() + " " + u.id + ": ships " + built + " of " + Owed()
            + ", fighters " + fighters + " of " + (PerShip() * Owed()) + ", held " + held.length() + "+" + heldFighters.length()
            + " for wave " + (waves + 1), 1);
        return true;
    }

    IUnitTask@ MilitaryTask(CCircuitUnit@ u)
    {
        if (!Selected() || u is null) return null;
        const bool ship = held.find(u.id) >= 0;
        if (!ship && heldFighters.find(u.id) < 0) return null;
        IUnitTask@ stage;
        if (staging.get("" + u.id, @stage) && stage !is null && !stage.IsDead()) return stage;
        @stage = AirWaves::StagingTask(u, ship);   // fighters patrol and fire at will at home
        if (stage is null) return null;
        if (ship && !AirLiches::IsLiche(u.circuitDef)) u.SetFireState(2);   // a Dragon or Tyrannus defends the base while it waits
        staging.set("" + u.id, @stage);
        return stage;
    }

    void ReleaseStaging(int id)
    {
        IUnitTask@ stage;
        if (staging.get("" + id, @stage) && stage !is null && !stage.IsDead()) stage.Abort();
        staging.delete("" + id);
    }

    void Removed(CCircuitUnit@ u)
    {
        if (u is null) return;
        int i = held.find(u.id);
        if (i >= 0) held.removeAt(i);
        i = heldFighters.find(u.id);
        if (i >= 0) heldFighters.removeAt(i);
        ReleaseStaging(u.id);
    }

    /**************************************************************************
     The wave: once a second.
     **************************************************************************/
    array<CCircuitUnit@>@ Live(array<int>@ ids)
    {
        array<CCircuitUnit@> units;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null) units.insertLast(u);
        }
        return units;
    }

    void Tick()
    {
        if (!Selected() || ai.frame < nextTick) return;
        nextTick = ai.frame + SECOND;
        UpdateSteps();
        const int end = BatchEnd(waves + 1);
        if (held.length() == 0 || built < end || fighters < PerShip() * end) return;
        // the batch's ships and fighters are done: one wave
        array<CCircuitUnit@>@ ships = Live(held);
        array<CCircuitUnit@>@ escorts = Live(heldFighters);
        held.resize(0); heldFighters.resize(0);
        ++waves;
        aiTerrainMgr.SetLayoutInt(StateKey + "waves", waves);
        GenericHelpers::LogUtil("[TECH][Capital] wave " + waves + " assembled: " + ships.length() + " " + UnitName() + " + "
            + escorts.length() + " " + FighterName() + " (" + built + " ships built): attack", 1);
        Attack(ships);
        Escort(ships, escorts);
    }

    void Attack(array<CCircuitUnit@>@ units)
    {
        // Transfer first, then end the staging route: an aborted route with its unit
        // still aboard would send it through MakeTask again.
        array<CCircuitUnit@> liches;
        for (uint i = 0; i < units.length(); ++i) {
            CCircuitUnit@ u = units[i];
            if (AirLiches::IsLiche(u.circuitDef)) { liches.insertLast(u); continue; }
            IUnitTask@ t = aiMilitaryMgr.DefaultMakeTask(u);
            if (t !is null) aiMilitaryMgr.TransferUnit(u, t);
            ReleaseStaging(u.id);
        }
        if (liches.length() > 0) Siege(liches);
        for (uint i = 0; i < liches.length(); ++i) ReleaseStaging(liches[i].id);
        if (units.length() > liches.length())
            GenericHelpers::LogUtil("[TECH][Capital] " + (units.length() - liches.length()) + " " + UnitName() + " sent to native attack", 1);
    }

    void Siege(array<CCircuitUnit@>@ liches)
    {
        CEscortStrikeTask@ et = NewEscortStrike();
        if (et is null) return;
        AirLiches::InitRoster();
        AirLiches::_Allow(et);
        et.SetSiege(true);
        et.SetHome(Global::Map::StartPos);   // a Liche with no scouted target waits at home
        et.SetStrikePolicy(0.0f, Global::RoleSettings::Tech::CapitalRushLichesPerTarget,
            Global::RoleSettings::Tech::CapitalRushLicheOrderSeconds);
        int n = 0;
        for (uint i = 0; i < liches.length(); ++i)
            if (aiMilitaryMgr.TransferUnit(liches[i], AsTask(et))) ++n;
        if (n == 0) { et.Abort(); return; }
        GenericHelpers::LogUtil("[TECH][Capital] siege: " + n + " armliche strike scouted Liche-roster targets, "
            + Global::RoleSettings::Tech::CapitalRushLichesPerTarget + " per target", 1);
    }

    // Each ship's fighters guard it (fighter mode, no strike roster); the extra
    // fighters of ships lost at home go round the living ships. No ship left:
    // the fighters go to native defaults.
    void Escort(array<CCircuitUnit@>@ ships, array<CCircuitUnit@>@ escorts)
    {
        if (escorts.length() == 0) return;
        if (ships.length() == 0) {
            for (uint i = 0; i < escorts.length(); ++i) {
                IUnitTask@ t = aiMilitaryMgr.DefaultMakeTask(escorts[i]);
                if (t !is null) aiMilitaryMgr.TransferUnit(escorts[i], t);
                ReleaseStaging(escorts[i].id);
            }
            return;
        }
        array<CEscortStrikeTask@> guards;
        for (uint s = 0; s < ships.length(); ++s) {
            CEscortStrikeTask@ et = NewEscortStrike();
            if (et !is null) { et.SetFighterEscort(true); et.AddEscortTarget(ships[s].id); }
            guards.insertLast(et);
        }
        int n = 0;
        for (uint i = 0; i < escorts.length(); ++i) {
            CEscortStrikeTask@ et = guards[(i / AiMax(1, PerShip())) % guards.length()];
            if (et !is null && aiMilitaryMgr.TransferUnit(escorts[i], AsTask(et))) ++n;
            ReleaseStaging(escorts[i].id);
        }
        for (uint s = 0; s < guards.length(); ++s)
            if (guards[s] !is null && guards[s].GetUnits().length() == 0) guards[s].Abort();
        GenericHelpers::LogUtil("[TECH][Capital] escort: " + n + " " + FighterName() + " guard " + ships.length() + " " + UnitName(), 1);
    }

    // One implicit cast per step: CEscortStrikeTask -> IFighterTask -> IUnitTask.
    IUnitTask@ AsTask(CEscortStrikeTask@ et) { IFighterTask@ f = et; IUnitTask@ t = f; return t; }

    CEscortStrikeTask@ NewEscortStrike()
    {
        IUnitTask@ raw = aiMilitaryMgr.EnqueueEscortStrike();
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CEscortStrikeTask@ et = (ft is null) ? null : cast<CEscortStrikeTask>(ft);
        if (et is null && raw !is null) raw.Abort();
        return et;
    }
}
