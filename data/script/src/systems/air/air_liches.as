// AIR role: Armada Liches (armliche), owner 2026-10-17.
#include "air_operations.as"
#include "air_strike_tiers.as"

/******************************************************************************

LICHES

Off unless Global::RoleSettings::Air::LichesEnabled (experimental_balanced turns
it on). Armada only: no other faction builds a Liche.

Production (AirProduction::MakeTask, T2 plant, bomber block): once the 10 s
minimum metal income has reached LicheMetalIncome the gate latches for the game.
From then on every LicheOrderEvery-th T2 bomber order is a Liche (every order
while the Phoenix pool is full) until LicheReserve Liches are held or building
beyond those already on a run.

Hold: a finished Liche stages at home on the same route task as the held
Phoenixes, fire held. The base response never takes one (AirBaseResponse::Kind):
a nuclear missile is not a weapon for our own base.

Launch (AirWaves::_Launch -> LaunchWith): every offensive T2 bomber wave takes
the held Liches with it. Owner 2026-10-24: the Liches fly WITH the wave, not
ahead of it. Faster than the Phoenixes, on their own route they outran the
wave's fighters and died before reaching their target (2026-10-23 live game,
team 13: five runs at one anti-nuke, no hit; the run only ordered its ATTACK on
the last leg of its route). So the Liches no longer fly an operation of their
own. They join one native CEscortStrikeTask (src/circuit/task/fighter/
EscortStrikeTask.*, not the bombers' CAirWaveTask) that:
  - guards one living bomber of the wave: one GUARD per Liche, issued once;
    the wave's own fighters cover them because they stay over the wave;
  - when that bomber dies, guards the living wave bomber nearest the Liches
    (one GUARD per Liche again);
  - keeps every Liche on its guard until a roster target is IN SIGHT within
    StrikeRadius() of it (the T2 bombers' StrikeImmediateRadius, 1800;
    owner 2026-10-26), then breaks it off at once with one ATTACK on that unit.
    A radar dot or a structure only remembered does not break the guard
    (owner 2026-10-25: they split off before they had found a target). At
    most LicheStrikersPerTarget Liches take one target; the rest keep
    guarding and take the next one;
  - if the target drops out of sight during the strike, bombs the spot where
    it was last seen (one ATTACK ground), and takes the unit again if it is
    seen again;
  - puts the Liche back on its guard when the target is dead, the ATTACK has
    finished or it has run LicheStrikeSeconds;
  - sends a Liche home (idle -> MakeTask -> staged and held for the next wave)
    when no wave bomber is left alive.
Every unit and enemy is held natively by id and resolved at use; no order is
re-issued while one stands (lag fix, 2026-10-23). A defensive sortie
leaves the Liches at home. The T2 bomber wave code (air_waves.as,
CAirWaveTask) is unchanged.

Targets, best tier first, then nearest (the tier is the priority; cost does
not enter):
  1 shields       Keeper, Overseer, Soteria
  2 heavy defence Pulsar, Bulwark, Bastion, Cerberus
  3 strategic     Citadel, Prevailer, Aegis, Rampart, Umbrella, Saviour, Hera,
                  Armageddon, Apocalypse, Supernova, advanced geothermals
  4 geothermal    geothermals, Prude
  5 gantries      all T3 gantries
  6 commanders    every def with the commander role (owner 2026-10-28: above T2 factories)
  7 T2 factories  advanced air, vehicle, bot and sea plants
  8 T3 units      every unit a gantry builds (owner 2026-10-28: last, so Liches bomb the T3s that
                  reach our base when nothing above is in range or scouted)
A target counts only while in sight, structures included.

******************************************************************************/
namespace AirLiches {
    const string Name = "armliche";
    dictionary held;                  // id string -> true: finished Liches staged at home
    array<CEscortStrikeTask@> runs;   // live Liche escorts
    array<IUnitTask@> raids;          // parallel to runs: the bomber wave each one flies with
    array<int> runStrikes;            // parallel to runs: strikes issued when last logged
    AirStrikeTiers::Roster roster;    // the eight Liche tiers
    int ordersSinceLiche = 0;

    bool Enabled() { return Global::RoleSettings::Air::LichesEnabled && AirEconomy::Active(); }
    bool IsLiche(const CCircuitDef@ d) { return d !is null && d.GetName() == Name; }
    // The T2 bombers' in-flight retarget radius times LicheStrikeRadiusShare (1800, owner 2026-10-26).
    float StrikeRadius()
    {
        return Global::RoleSettings::Air::StrikeImmediateRadius * Global::RoleSettings::Air::LicheStrikeRadiusShare;
    }

    void Init()
    {
        held.deleteAll(); runs.resize(0); raids.resize(0); runStrikes.resize(0); ordersSinceLiche = 0;
    }

    /**************************************************************************
     Target roster (once: definitions do not change during a game).
     **************************************************************************/
    void InitRoster()
    {
        if (roster.Ready()) return;
        roster.Begin("Liche", 8);
        roster.Add(1, array<string> = {"armgate", "corgate", "legdeflector"}, Global::RoleSettings::Air::LicheWeightShields);
        roster.Add(2, array<string> = {"armanni", "cordoom", "legbastion", "corbhmth"}, Global::RoleSettings::Air::LicheWeightHeavyDefence);
        roster.Add(3, array<string> = {"armamd", "corfmd", "legabm", "legrampart", "armscab", "cormabm", "legavantinuke",
            "armsilo", "corsilo", "legsilo",
            "armageo", "corageo", "legageo", "armuwageo", "coruwageo", "leganavaladvgeo"},
            Global::RoleSettings::Air::LicheWeightStrategic);
        roster.Add(4, array<string> = {"armgeo", "corgeo", "leggeo", "armuwgeo", "coruwgeo", "leguwgeo", "armgmm"},
            Global::RoleSettings::Air::LicheWeightGeo);
        roster.Add(5, UnitHelpers::GetAllGantries(), Global::RoleSettings::Air::LicheWeightGantry);
        // owner, 2026-10-28: commanders above the T2 factories; every def with the commander role (O(defs), once)
        // owner, 2026-10-28: and every unit a gantry builds, last. O(defs x gantries), once.
        array<string> commanders, t3;
        array<CCircuitDef@> gantries;
        array<string> gantryNames = UnitHelpers::GetAllGantries();
        for (uint g = 0; g < gantryNames.length(); ++g) {
            CCircuitDef@ gd = ai.GetCircuitDef(gantryNames[g]);
            if (gd !is null) gantries.insertLast(gd);
        }
        for (int i = 1; i <= ai.GetDefCount(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(i);
            if (d is null) continue;
            if (UnitHelpers::IsCommander(d)) { commanders.insertLast(d.GetName()); continue; }
            if (!d.IsMobile()) continue;
            for (uint g = 0; g < gantries.length(); ++g)
                if (gantries[g].CanBuild(d)) { t3.insertLast(d.GetName()); break; }
        }
        roster.Add(6, commanders, Global::RoleSettings::Air::LicheWeightCommander);
        roster.Add(7, array<string> = {"armaap", "armavp", "armalab", "armasy", "coraap", "coravp", "coralab", "corasy",
            "legaap", "legavp", "legalab", "legadvshipyard"}, Global::RoleSettings::Air::LicheWeightT2Factory);
        roster.Add(8, t3, Global::RoleSettings::Air::LicheWeightT3Unit);
        roster.Finish();
    }
    // Priority = tier rank (tier 1 -> 6 ... tier 6 -> 1): the tier decides, then the native task takes
    // the nearest. O(defs) once per launch.
    void _Allow(CEscortStrikeTask@ et)
    {
        for (int i = 0; i < int(roster.tierByDef.length()); ++i)
            if (roster.tierByDef[i] > 0)
                et.AllowStrikeDef(ai.GetCircuitDef(i), float(roster.tiers + 1 - roster.tierByDef[i]));
    }

    /**************************************************************************
     Production.
     **************************************************************************/
    bool Unlocked()
    {
        if (aiTerrainMgr.GetLayoutInt("air.liche.unlocked", 0) != 0) return true;
        if (!Economy::IncomeWindowReady()
            || Economy::GetMinMetalIncomeLast10s() < Global::RoleSettings::Air::LicheMetalIncome) return false;
        aiTerrainMgr.SetLayoutInt("air.liche.unlocked", 1);
        GenericHelpers::LogUtil("[AIR][Liche] production unlocked at M10=" + int(Economy::GetMinMetalIncomeLast10s()), 1);
        return true;
    }
    // Liches wanted alive: those on a run plus the home reserve.
    int Target() { return AirOperations::BomberCount(Name) + Global::RoleSettings::Air::LicheReserve; }
    // Held or building, not on a run.
    int Pool()
    {
        if (!Global::RoleSettings::Air::LichesEnabled) return 0;
        CCircuitDef@ d = ai.GetCircuitDef(Name);
        return d is null ? 0 : AiMax(0, AirProduction::Projected(d) - AirOperations::BomberCount(Name));
    }
    bool Turn(const string &in side, bool bombersWanted)
    {
        if (!Enabled() || side != "armada" || Global::RoleSettings::Air::LicheReserve <= 0) return false;
        CCircuitDef@ d = ai.GetCircuitDef(Name);
        if (d is null || AirProduction::Projected(d) >= Target() || !Unlocked()) return false;
        return !bombersWanted || ordersSinceLiche >= AiMax(1, Global::RoleSettings::Air::LicheOrderEvery) - 1;
    }
    void Ordered(bool liche) { ordersSinceLiche = liche ? 0 : ordersSinceLiche + 1; }

    /**************************************************************************
     Hold (Military::AiMakeTask).
     **************************************************************************/
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || !IsLiche(u.circuitDef)) return null;
        IUnitTask@ stage = AirWaves::StagingTask(u, true);
        if (stage !is null) held.set("" + u.id, true);
        return stage;
    }

    /**************************************************************************
     Launch with an offensive bomber wave, after its bombers joined `raid` and
     before its fighters do. The Liches guard the wave's bombers and take
     their own targets within StrikeRadius() (see the header). They take no
     fighters of their own (`spareFighters` is unused): the wave's escort covers
     them because they stay over the wave. Returns the Liches launched.
     **************************************************************************/
    int LaunchWith(int spareFighters, CAirWaveTask@ raid)
    {
        if (!Enabled() || raid is null || raid.IsDead()) return 0;
        array<string>@ ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u is null || u.GetBuildProgress() < 1.0f
                || (u.task !is null && u.task.GetType() == int(Task::Type::PLAYER))) held.delete(ids[i]);
        }
        if (held.isEmpty()) return 0;
        // Escort targets: the wave's bombers, by id. Its fighters join after this call.
        array<int> bombers;
        array<CCircuitUnit@>@ members = raid.GetUnits();
        for (uint i = 0; i < members.length(); ++i)
            if (members[i] !is null && AirWaves::IsWaveBomber(members[i].circuitDef)) bombers.insertLast(members[i].id);
        if (bombers.length() == 0) return 0;
        IUnitTask@ raw = aiMilitaryMgr.EnqueueEscortStrike();
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CEscortStrikeTask@ et = (ft is null) ? null : cast<CEscortStrikeTask>(ft);
        if (et is null) {
            if (raw !is null) raw.Abort();
            return 0;
        }
        InitRoster();
        _Allow(et);
        et.SetStrikePolicy(StrikeRadius(), Global::RoleSettings::Air::LicheStrikersPerTarget,
            Global::RoleSettings::Air::LicheStrikeSeconds);
        for (uint i = 0; i < bombers.length(); ++i) et.AddEscortTarget(bombers[i]);
        dictionary cohort;
        @ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null && aiMilitaryMgr.TransferUnit(u, raw)) { cohort.set(ids[i], int(u.id)); held.delete(ids[i]); }
        }
        if (cohort.isEmpty()) { raw.Abort(); return 0; }
        AirOperations::TrackBombers(raw, cohort); // Liches on a run count toward Target()
        runs.insertLast(et); raids.insertLast(raid); runStrikes.insertLast(0);
        GenericHelpers::LogUtil("[AIR][Liche] launched liches=" + cohort.getSize() + " guarding wave bombers=" + bombers.length()
            + " vip=" + et.GetVipId() + " strikeRadius=" + int(StrikeRadius())
            + " perTarget=" + Global::RoleSettings::Air::LicheStrikersPerTarget
            + " raidTarget=" + raid.GetStrikeTargetId() + " raidAim=" + int(raid.GetAim().x) + "," + int(raid.GetAim().z), 1);
        return int(cohort.getSize());
    }

    /**************************************************************************
     Air_MainUpdate, every 30 frames. The native task does the flying; this only
     ends an escort whose wave is over while its Liches still have a bomber to
     guard (bombers that left the wave alive), so they come home to be held for
     the next wave, and logs each run's strike count when it changes.
     **************************************************************************/
    void Update()
    {
        for (int i = int(runs.length()) - 1; i >= 0; --i) {
            CEscortStrikeTask@ et = runs[i];
            if (et is null || et.IsDead()) {
                if (et !is null)
                    GenericHelpers::LogUtil("[AIR][Liche] run over strikes=" + et.GetStrikesIssued() + " fired=" + et.GetShotsFired()
                        + " destroyed=" + et.GetTargetsDestroyed(), 1);
                runs.removeAt(i); raids.removeAt(i); runStrikes.removeAt(i);
                continue;
            }
            if ((raids[i] is null || raids[i].IsDead()) && et.GetStriking() == 0) {
                GenericHelpers::LogUtil("[AIR][Liche] wave over: escort ends, liches=" + et.GetUnits().length() + " go home; strikes="
                    + et.GetStrikesIssued() + " fired=" + et.GetShotsFired() + " destroyed=" + et.GetTargetsDestroyed(), 1);
                et.Abort();
                runs.removeAt(i); raids.removeAt(i); runStrikes.removeAt(i);
                continue;
            }
            if (et.GetStrikesIssued() != runStrikes[i]) {
                runStrikes[i] = et.GetStrikesIssued();
                GenericHelpers::LogUtil("[AIR][Liche] run strikes=" + et.GetStrikesIssued() + " striking=" + et.GetStriking()
                    + " fired=" + et.GetShotsFired() + " destroyed=" + et.GetTargetsDestroyed() + " vip=" + et.GetVipId(), 1);
            }
        }
    }

    void Removed(CCircuitUnit@ u) { if (u !is null) held.delete("" + u.id); }
    // AirProduction::Leave: held Liches return to native defaults; their staging tasks are aborted there.
    array<string>@ HeldIds() { return held.getKeys(); }
}  // namespace AirLiches
