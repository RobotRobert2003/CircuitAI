#include "../../global.as"
#include "../../systems/air/air_liches.as"

/******************************************************************************

CAPITAL RUSH (owner, 2026-10-26; Strategy::CAPITAL_RUSH, plan "capitalrush")

The T2 aircraft plant builds the side's capital bomber: Liche (armliche),
Dragon (corcrwh) or Tyrannus (legfort) (CapitalRushUnits).

Gate: the 10 s minimum metal income reaches CapitalRushMetalIncome (150) and
the plant has its dedicated constructors (D-108, filled ahead of this in
Tech_FactoryAiMakeTask). From then on the plant builds nothing but the
bomber while a batch is owed: CapitalRushFirstBatch (5), then
CapitalRushNextBatch (10) more for every CapitalRushMetalStep (100) of income
above the gate, reached once (one-way: a dip cancels nothing). Between
batches the plant's ordinary production resumes.

A finished bomber is held at home (AirWaves::StagingTask). When the batch is
complete it is one wave:
  - an AIR ally on the roster: the whole batch is given to it (GiveUnits);
    AIR uses it as its own (Liches: AirLiches, guarding its bomber waves;
    Dragons and Tyrannus: AIR's base response or native attack). A unit
    still ours a few seconds later (the gift refused) goes out as below;
  - no AIR ally: Liches join one native CEscortStrikeTask in siege mode
    (EscortStrikeTask.h): AIR's Liche roster (AirLiches::InitRoster,
    shields first), CapitalRushLichesPerTarget on each scouted target
    anywhere, the unit while in sight, else ATTACK ground on its last known
    spot (as a Juno), kept until it no longer exists. Dragons and Tyrannus
    go to native attack (DefaultMakeTask) together.

Cost: the factory hook is O(1) per factory ask; Tick runs once a second
(TechHeavyRush cadence) over the held batch only (at most
CapitalRushNextBatch units). Orders: one staging route per bomber, one
transfer or one gift per wave.

******************************************************************************/
namespace TechCapitalRush {
    const string StateKey = "tech.capital.";
    int built = 0;         // bombers finished, every batch together
    int steps = 0;         // batches unlocked by income (one-way)
    int waves = 0;         // batches sent
    int nextTick = 0;
    int nextTrace = 0;
    int originalCap = -1;
    IUnitTask@ recruit;
    array<int> held;       // finished bombers of the batch in progress, staged at home
    dictionary staging;    // unit id -> its staging route task
    array<int> gifted;     // the last gift, checked once it settles
    int giftRecipient = -1;
    int giftFrame = -1;
    array<int> refusedRecipients;

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
    bool IsCapital(CCircuitUnit@ u) { return u !is null && u.circuitDef !is null && u.circuitDef.GetName() == UnitName(); }

    void Init()
    {
        built = aiTerrainMgr.GetLayoutInt(StateKey + "built", 0);
        steps = aiTerrainMgr.GetLayoutInt(StateKey + "steps", 0);
        waves = aiTerrainMgr.GetLayoutInt(StateKey + "waves", 0);
        @recruit = null;
        held.resize(0); staging.deleteAll(); gifted.resize(0); refusedRecipients.resize(0);
        if (!Selected()) return;
        CCircuitDef@ d = ai.GetCircuitDef(UnitName());
        originalCap = (d is null) ? -1 : d.maxThisUnit;
        GenericHelpers::LogUtil("[TECH][Capital] selected: " + UnitName() + " from +" + int(Global::RoleSettings::Tech::CapitalRushMetalIncome)
            + " metal, " + Global::RoleSettings::Tech::CapitalRushFirstBatch + " then " + Global::RoleSettings::Tech::CapitalRushNextBatch
            + " per +" + int(Global::RoleSettings::Tech::CapitalRushMetalStep), 1);
    }

    // Bombers owed by the end of batch k (1-based).
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
        GenericHelpers::LogUtil("[TECH][Capital] income +" + int(income) + ": batch " + steps + " unlocked, " + Owed() + " owed in all ("
            + built + " built)", 1);
    }

    void RestoreCap()
    {
        CCircuitDef@ d = ai.GetCircuitDef(UnitName());
        if (d !is null && originalCap >= 0 && d.maxThisUnit != originalCap) d.maxThisUnit = originalCap;
    }

    void Blocked(const string &in reason)
    {
        if (ai.frame < nextTrace) return;
        nextTrace = ai.frame + 30 * SECOND;
        GenericHelpers::LogUtil("[TECH][Capital] waiting: " + reason + " (built " + built + " of " + Owed() + ")", 1);
    }

    /**************************************************************************
     Production (Tech_FactoryAiMakeTask, after the D-108 air constructors).
     **************************************************************************/
    IUnitTask@ Produce(CCircuitUnit@ factory, const string &in side)
    {
        if (!Selected() || factory is null || factory.circuitDef is null
            || factory.circuitDef.GetName() != UnitHelpers::GetT2AirPlantForSide(side)) return null;
        UpdateSteps();
        if (built >= Owed()) { RestoreCap(); return null; }   // between batches: ordinary production
        CCircuitDef@ d = ai.GetCircuitDef(UnitName());
        if (d is null || !factory.circuitDef.CanBuild(d)) { Blocked("no " + UnitName() + " at " + factory.circuitDef.GetName()); return null; }
        if (recruit !is null && !recruit.IsDead()) return recruit;
        if (aiFactoryMgr.GetPendingRecruitCount(d) > 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        if (d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;   // TECH's start caps may hold it at 0
        if (!d.IsAvailable(ai.frame)) { Blocked(UnitName() + " not available"); return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND)); }
        @recruit = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, factory.GetPos(ai.frame), 64.f));
        if (recruit !is null)
            GenericHelpers::LogUtil("[TECH][Capital] recruit " + UnitName() + " number=" + (built + 1) + " of " + Owed()
                + " (batch " + steps + ") at " + factory.circuitDef.GetName() + " " + factory.id, 1);
        return recruit;
    }

    /**************************************************************************
     Finished (Tech_MilitaryAiUnitAdded) and hold (Military::AiMakeTask).
     **************************************************************************/
    bool OnFinished(CCircuitUnit@ u)
    {
        if (!Selected() || !IsCapital(u) || u.GetBuildProgress() < 1.0f) return false;
        if (held.find(u.id) >= 0) return true;
        ++built;
        aiTerrainMgr.SetLayoutInt(StateKey + "built", built);
        held.insertLast(u.id);
        @recruit = null;
        if (built >= Owed()) RestoreCap();
        GenericHelpers::LogUtil("[TECH][Capital] finished " + UnitName() + " " + u.id + ": " + built + " of " + Owed()
            + ", held " + held.length() + " for wave " + (waves + 1), 1);
        return true;
    }

    IUnitTask@ MilitaryTask(CCircuitUnit@ u)
    {
        if (!Selected() || u is null || held.find(u.id) < 0) return null;
        IUnitTask@ stage;
        if (staging.get("" + u.id, @stage) && stage !is null && !stage.IsDead()) return stage;
        @stage = AirWaves::StagingTask(u, true);
        if (stage is null) return null;
        if (!AirLiches::IsLiche(u.circuitDef)) u.SetFireState(2);   // a Dragon or Tyrannus defends the base while it waits
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
        const int i = held.find(u.id);
        if (i >= 0) held.removeAt(i);
        ReleaseStaging(u.id);
    }

    /**************************************************************************
     The wave: once a second.
     **************************************************************************/
    int Recipient()
    {
        array<Team::Roster::Entry@>@ allies = Team::Roster::WithRole(AiRole::AIR);
        int best = -1;
        float distance = 1e30f;
        for (uint i = 0; i < allies.length(); ++i) {
            Team::Roster::Entry@ e = allies[i];
            if (e is null || e.teamId == ai.teamId || refusedRecipients.find(e.teamId) >= 0) continue;
            const float sq = MapHelpers::SqDist(Global::Map::StartPos, e.startPos);
            if (sq < distance || (sq == distance && e.teamId < best)) { distance = sq; best = e.teamId; }
        }
        return best;
    }

    void Tick()
    {
        if (!Selected() || ai.frame < nextTick) return;
        nextTick = ai.frame + SECOND;
        UpdateSteps();
        CheckGift();
        if (held.length() == 0 || built < BatchEnd(waves + 1)) return;
        // the batch is complete: one wave
        array<CCircuitUnit@> units;
        for (uint i = 0; i < held.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(held[i]);
            if (u !is null) units.insertLast(u);
        }
        array<int> ids = held;
        held.resize(0);
        ++waves;
        aiTerrainMgr.SetLayoutInt(StateKey + "waves", waves);
        const int recipient = Recipient();
        GenericHelpers::LogUtil("[TECH][Capital] wave " + waves + " assembled: " + units.length() + " " + UnitName()
            + " (" + built + " built); " + (recipient >= 0 ? "trade to AIR team " + recipient : "no AIR ally: attack"), 1);
        if (units.length() == 0) return;
        if (recipient >= 0) {
            ai.GiveUnits(units, recipient);
            gifted = ids; giftRecipient = recipient; giftFrame = ai.frame;
            for (uint i = 0; i < ids.length(); ++i) ReleaseStaging(ids[i]);
            return;
        }
        Attack(units);
    }

    // A gift the engine refused leaves the units ours: that AIR is not taken again, they attack.
    void CheckGift()
    {
        if (gifted.length() == 0 || ai.frame < giftFrame + 3 * SECOND) return;
        array<CCircuitUnit@> kept;
        int given = 0;
        for (uint i = 0; i < gifted.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(gifted[i]);
            if (u !is null) kept.insertLast(u);
            else if (ai.GetFriendlyUnitTeam(gifted[i]) == giftRecipient) ++given;
        }
        GenericHelpers::LogUtil("[TECH][Capital] traded " + given + " " + UnitName() + " to AIR team " + giftRecipient
            + (kept.length() > 0 ? "; " + kept.length() + " refused, they attack" : ""), 1);
        if (kept.length() > 0) {
            refusedRecipients.insertLast(giftRecipient);
            Attack(kept);
        }
        gifted.resize(0); giftRecipient = -1;
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
        IUnitTask@ raw = aiMilitaryMgr.EnqueueEscortStrike();
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CEscortStrikeTask@ et = (ft is null) ? null : cast<CEscortStrikeTask>(ft);
        if (et is null) {
            if (raw !is null) raw.Abort();
            return;
        }
        AirLiches::InitRoster();
        AirLiches::_Allow(et);
        et.SetSiege(true);
        et.SetStrikePolicy(0.0f, Global::RoleSettings::Tech::CapitalRushLichesPerTarget,
            Global::RoleSettings::Tech::CapitalRushLicheOrderSeconds);
        int n = 0;
        for (uint i = 0; i < liches.length(); ++i)
            if (aiMilitaryMgr.TransferUnit(liches[i], raw)) ++n;
        if (n == 0) { raw.Abort(); return; }
        GenericHelpers::LogUtil("[TECH][Capital] siege: " + n + " armliche strike scouted Liche-roster targets, "
            + Global::RoleSettings::Tech::CapitalRushLichesPerTarget + " per target", 1);
    }
}
