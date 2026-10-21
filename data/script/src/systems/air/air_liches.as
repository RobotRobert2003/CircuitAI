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

Launch (AirWaves::_Launch): every offensive T2 bomber wave takes the held Liches
with it as a second CAirWaveTask. Both assemble at the start position and leave
together; the Liche operation picks its own target from its own weights, but
only inside the raid's district: within LicheRaidRadius of the bomber wave's
aim (owner, 2026-10-21). Before that the Liches chose anywhere on the map and
flew off on their own (Project SD-129: bombers north at 7288,1304, Liches
south at 5680,12896), and stayed home whenever no tier target was known
anywhere. With no tier target in the district they still go, on the raid's
fallbacks there. A defensive sortie leaves the Liches at home. Escorts: only
fighters beyond the bomber wave's own escort need go with the Liches.

The district is native exclusion: ExcludeStrikeRegion takes at most 8 discs of
radius <= 10000, so eight such discs whose near edges stand LicheRaidRadius
from the raid aim leave a free octagon (circumradius ~1.08 x LicheRaidRadius)
around it. Every pick of the run, in flight and after a kill, stays inside.

Targets (native CAirWaveTask, preference 5 = allowed statics by weight; the
tier mechanics are shared with the T2 bombers in air_strike_tiers.as):
  1 shields       Keeper, Overseer, Soteria
  2 heavy defence Pulsar, Bulwark, Bastion, Cerberus
  3 strategic     Citadel, Prevailer, Aegis, Rampart, Umbrella, Saviour, Hera,
                  Armageddon, Apocalypse, Supernova, advanced geothermals
  4 geothermal    geothermals, Prude
  5 gantries      all T3 gantries
  6 T2 factories  advanced air, vehicle, bot and sea plants
The native scorer multiplies a def's weight by its metal cost, so each def gets
TierWeight * 1000 / cost: cost cancels and the tier decides, then distance and
route risk. With no feasible static target in the district the launch falls
back to a mobile anti-nuke (native class 7), then turrets, other economy and
any structure there. After the first kill the run keeps descending the same way.

In flight (Update, every second): the native immediate strike retargets to the
best visible allowed static within LicheImmediateRadius (900, half the
bombers' 1800: a homing missile with range 250 needs no long run-up) of the Liches whose
weight is at least the handoff threshold, and keeps the current target while
its own weight reaches it. The threshold is set to the lowest weight of the
tier just above the current target's, so only a strictly higher tier takes
over: a shield seen on the way to a factory is bombed first, but two Pulsars
never steal each other's passes. A shield target keeps itself.

Native limits (no script control): mobile anti-nukes never take over in flight
(the immediate strike only considers stationary units) and are chosen only
when no weighted static target is feasible.

******************************************************************************/
namespace AirLiches {
    const string Name = "armliche";
    dictionary held;               // id string -> true: finished Liches staged at home
    array<CAirWaveTask@> runs;     // live Liche operations
    array<int> runTarget;          // parallel to runs: target id * 8 + tier last logged
    AirStrikeTiers::Roster roster; // the six Liche tiers
    int ordersSinceLiche = 0;
    int lastHoldLog = -100000;

    bool Enabled() { return Global::RoleSettings::Air::LichesEnabled && AirEconomy::Active(); }
    bool IsLiche(const CCircuitDef@ d) { return d !is null && d.GetName() == Name; }

    void Init()
    {
        held.deleteAll(); runs.resize(0); runTarget.resize(0); roster.seenTier.deleteAll(); ordersSinceLiche = 0; lastHoldLog = -100000;
    }

    /**************************************************************************
     Target roster (once: definitions do not change during a game).
     **************************************************************************/
    void InitRoster()
    {
        if (roster.Ready()) return;
        roster.Begin("Liche", 6);
        roster.Add(1, array<string> = {"armgate", "corgate", "legdeflector"}, Global::RoleSettings::Air::LicheWeightShields);
        roster.Add(2, array<string> = {"armanni", "cordoom", "legbastion", "corbhmth"}, Global::RoleSettings::Air::LicheWeightHeavyDefence);
        roster.Add(3, array<string> = {"armamd", "corfmd", "legabm", "legrampart", "armscab", "cormabm", "legavantinuke",
            "armsilo", "corsilo", "legsilo",
            "armageo", "corageo", "legageo", "armuwageo", "coruwageo", "leganavaladvgeo"},
            Global::RoleSettings::Air::LicheWeightStrategic);
        roster.Add(4, array<string> = {"armgeo", "corgeo", "leggeo", "armuwgeo", "coruwgeo", "leguwgeo", "armgmm"},
            Global::RoleSettings::Air::LicheWeightGeo);
        roster.Add(5, UnitHelpers::GetAllGantries(), Global::RoleSettings::Air::LicheWeightGantry);
        roster.Add(6, array<string> = {"armaap", "armavp", "armalab", "armasy", "coraap", "coravp", "coralab", "corasy",
            "legaap", "legavp", "legalab", "legadvshipyard"}, Global::RoleSettings::Air::LicheWeightT2Factory);
        roster.Finish();
        AirStrikeTiers::Register(@roster);
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
     Launch with an offensive bomber wave. `spareFighters` are the fighters
     beyond the bomber wave's own escort; `raid` is the wave, already planned.
     The Liches pick their own target, but only in the raid's district.
     Returns the Liches launched.
     **************************************************************************/
    int LaunchWith(int spareFighters, CAirWaveTask@ raid)
    {
        if (!Enabled() || raid is null) return 0;
        array<string>@ ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u is null || u.GetBuildProgress() < 1.0f
                || (u.task !is null && u.task.GetType() == int(Task::Type::PLAYER))) held.delete(ids[i]);
        }
        const int available = int(held.getSize());
        if (available == 0) return 0;
        CCircuitDef@ liche = ai.GetCircuitDef(Name);
        IUnitTask@ raw = aiMilitaryMgr.Enqueue(TaskF::Wave());
        IFighterTask@ ft = (raw is null) ? null : cast<IFighterTask>(raw);
        CAirWaveTask@ wt = (ft is null) ? null : cast<CAirWaveTask>(ft);
        if (wt is null || liche is null) {
            if (raw !is null) raw.Abort();
            return 0;
        }
        InitRoster();
        const AIFloat3 raidAim = raid.GetAim();
        AirWaves::ConfigureStrike(wt, liche, held, available);
        const float resistance = AirWaves::learnedResistance;
        wt.SetMissionPolicy(Global::RoleSettings::Air::StrikeCorridorPadding,
            Global::RoleSettings::Air::StrikeEdgeInset, Global::RoleSettings::Air::StrikeUnknownReserve + resistance - 1.0f,
            Global::RoleSettings::Air::StrikeRiskScale * resistance, Global::RoleSettings::Air::StrikeArmyReserve * resistance,
            Global::RoleSettings::Air::StrikeLocalAaReserve * resistance, Global::RoleSettings::Air::StrikeSynchronize);
        // The raid's own planning already kept clear of failed raid regions; the eight
        // exclusion slots all go to the district.
        _Configure(wt, raidAim);
        // Spare payload is not wasted: after the first kill the run keeps descending the tiers.
        wt.AddTargetFallback(7); // mobile anti-nukes
        wt.AddTargetFallback(3); // turrets
        wt.AddTargetFallback(4); // other economy and support structures
        wt.AddTargetFallback(0); // remaining structures
        // Aim at the raid first: the native frontline scorer measures from the plan's aim.
        wt.SetPlan(Task::WaveMode::STRIKE, raidAim, Global::RoleSettings::Air::WaveFormDistance,
            Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun,
            Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND, 0, Task::WAVE_SMART_BEARING, 1);
        bool picked = wt.PickStrikeTarget(Global::Map::StartPos, 5, 0.0f, false);
        const bool tiered = picked;
        if (!picked) picked = wt.PickOperationTarget(Global::Map::StartPos, 0.0f, false);
        if (!picked) {
            if (ai.frame - lastHoldLog >= 30 * SECOND) {
                lastHoldLog = ai.frame;
                GenericHelpers::LogUtil("[AIR][Liche] held: no feasible target within " + int(Global::RoleSettings::Air::LicheRaidRadius)
                    + " of the raid aim " + int(raidAim.x) + "," + int(raidAim.z) + " for " + available
                    + " Liche(s); fewest needed=" + wt.GetRequiredBombers(), 1);
            }
            raw.Abort();
            return 0;
        }
        wt.SetPlan(Task::WaveMode::STRIKE, wt.GetAim(), Global::RoleSettings::Air::WaveFormDistance,
            Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun,
            Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND, 0, Task::WAVE_SMART_BEARING, 1);
        dictionary cohort;
        @ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null && aiMilitaryMgr.TransferUnit(u, raw)) { cohort.set(ids[i], int(u.id)); held.delete(ids[i]); }
        }
        if (cohort.isEmpty()) { raw.Abort(); return 0; }
        const int escorts = AirOperations::AttachFighters(wt, true,
            AiMax(0, AiMin(spareFighters, AirWaves::FightersFor(int(cohort.getSize())))));
        AirOperations::TrackBombers(raw, cohort);
        runs.insertLast(wt); runTarget.insertLast(-1);
        AirStrikeTiers::Remember(true);
        const int tier = roster.TargetTier(wt.GetStrikeTargetId());
        _SetHandoff(wt, tier);
        GenericHelpers::LogUtil("[AIR][Liche] launched liches=" + cohort.getSize() + " escorts=" + escorts
            + " target=" + wt.GetStrikeTargetId() + " tier=" + tier + (tiered ? "" : " (raid fallback)")
            + " required=" + wt.GetRequiredBombers() + " aim=" + int(wt.GetAim().x) + "," + int(wt.GetAim().z)
            + " raidAim=" + int(raidAim.x) + "," + int(raidAim.z), 1);
        return int(cohort.getSize());
    }

    void _Configure(CAirWaveTask@ wt, const AIFloat3 &in raidAim)
    {
        wt.SetOperationPolicy(true, 5, Global::Map::StartPos, Global::RoleSettings::Air::StrikeEscortLead,
            Global::RoleSettings::Air::StrikeBacklineRiskLimit, Global::RoleSettings::Air::StrikeDistrictRadius);
        roster.Allow(wt);
        // A target lost from sight is searched for where the raid went, not at the enemy starts.
        wt.AddSearchPoint(raidAim);
        _ConfineTo(wt, raidAim, Global::RoleSettings::Air::LicheRaidRadius);
    }
    // Eight native exclusion discs (the most ExcludeStrikeRegion takes, radius <= 10000) whose near
    // edges stand `radius` from the centre: every target outside an octagon of circumradius about
    // 1.08 x radius is excluded, out to about 20000 elmos from the centre.
    void _ConfineTo(CAirWaveTask@ wt, const AIFloat3 &in centre, float radius)
    {
        const float disc = 10000.0f;
        const float reach = AiMax(256.0f, radius) + disc;
        for (int k = 0; k < 8; ++k) {
            const float a = float(k) * 0.7853982f;
            wt.ExcludeStrikeRegion(AIFloat3(centre.x + cos(a) * reach, 0.0f, centre.z + sin(a) * reach), disc);
        }
    }
    void _SetHandoff(CAirWaveTask@ wt, int tier)
    {
        wt.SetAttackHandoffPolicy(Global::RoleSettings::Air::StrikeEarlyAttack, roster.Threshold(tier),
            Global::RoleSettings::Air::LicheImmediateRadius);
    }

    /**************************************************************************
     In flight (Air_MainUpdate, every 30 frames): keep each run's handoff
     threshold one tier above its current target. Liche targets are remembered
     from the start for an Armada AIR (a chosen target is often one seen long
     before, out of radar now): one contact scan per second.
     **************************************************************************/
    void Update()
    {
        for (int i = int(runs.length()) - 1; i >= 0; --i)
            if (runs[i] is null || runs[i].IsDead()) { runs.removeAt(i); runTarget.removeAt(i); }
        if (!Enabled() || Global::AISettings::Side != "armada") return;
        InitRoster();
        AirStrikeTiers::Remember();
        for (uint r = 0; r < runs.length(); ++r) {
            const int target = runs[r].GetStrikeTargetId();
            const int tier = roster.TargetTier(target);
            _SetHandoff(runs[r], tier);
            if (target * 8 + tier == runTarget[r]) continue;
            runTarget[r] = target * 8 + tier;
            GenericHelpers::LogUtil("[AIR][Liche] run target=" + target + " tier=" + tier
                + " handoff=" + roster.Threshold(tier), 1);
        }
    }

    void Removed(CCircuitUnit@ u) { if (u !is null) held.delete("" + u.id); }
    // AirProduction::Leave: held Liches return to native defaults; their staging tasks are aborted there.
    array<string>@ HeldIds() { return held.getKeys(); }
}  // namespace AirLiches
