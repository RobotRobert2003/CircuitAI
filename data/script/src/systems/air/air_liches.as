// AIR role: Armada Liches (armliche), owner 2026-10-17.
#include "air_operations.as"

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
together; the Liche operation picks its own target from its own weights and
flies to it. A defensive sortie leaves the Liches at home. Escorts: only
fighters beyond the bomber wave's own escort need go with the Liches.

Targets (native CAirWaveTask, preference 5 = allowed statics by weight):
  1 shields       Keeper, Overseer, Soteria
  2 heavy defence Pulsar, Bulwark, Bastion, Cerberus
  3 strategic     Citadel, Prevailer, Aegis, Rampart, Umbrella, Saviour, Hera,
                  Armageddon, Apocalypse, Supernova, advanced geothermals
  4 geothermal    geothermals, Prude
  5 gantries      all T3 gantries
  6 T2 factories  advanced air, vehicle, bot and sea plants
The native scorer multiplies a def's weight by its metal cost, so each def gets
TierWeight * 1000 / cost: cost cancels and the tier decides, then distance and
route risk. With no feasible static target the launch falls back to a mobile
anti-nuke (native class 7). After the first kill the run keeps descending:
weighted statics, mobile anti-nukes, turrets, other economy, any structure.

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
    array<float> weightByDef;      // def id -> native strike weight, 0 = not a Liche target
    array<int> tierByDef;          // def id -> tier 1..6, 0 = none
    array<float> tierMin;          // tier -> lowest static weight in it (1..6)
    dictionary seenTier;           // enemy id string -> tier, for every Liche target seen as a ground contact
    bool rosterReady = false;
    int ordersSinceLiche = 0;
    int lastHoldLog = -100000;

    bool Enabled() { return Global::RoleSettings::Air::LichesEnabled && AirEconomy::Active(); }
    bool IsLiche(const CCircuitDef@ d) { return d !is null && d.GetName() == Name; }

    void Init()
    {
        held.deleteAll(); runs.resize(0); runTarget.resize(0); seenTier.deleteAll(); ordersSinceLiche = 0; lastHoldLog = -100000;
    }

    /**************************************************************************
     Target roster (once: definitions do not change during a game).
     **************************************************************************/
    void _AddTier(int tier, const array<string> &in names, float weight)
    {
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null || d.id < 0 || d.id >= int(tierByDef.length()) || tierByDef[d.id] != 0) continue;
            tierByDef[d.id] = tier;
            weightByDef[d.id] = weight * 1000.0f / AiMax(1.0f, d.costM);
        }
    }
    void InitRoster()
    {
        if (rosterReady) return;
        rosterReady = true;
        const int n = ai.GetDefCount() + 1;
        weightByDef.resize(n); tierByDef.resize(n);
        for (int i = 0; i < n; ++i) { weightByDef[i] = 0.0f; tierByDef[i] = 0; }
        _AddTier(1, array<string> = {"armgate", "corgate", "legdeflector"}, Global::RoleSettings::Air::LicheWeightShields);
        _AddTier(2, array<string> = {"armanni", "cordoom", "legbastion", "corbhmth"}, Global::RoleSettings::Air::LicheWeightHeavyDefence);
        _AddTier(3, array<string> = {"armamd", "corfmd", "legabm", "legrampart", "armscab", "cormabm", "legavantinuke",
            "armsilo", "corsilo", "legsilo",
            "armageo", "corageo", "legageo", "armuwageo", "coruwageo", "leganavaladvgeo"},
            Global::RoleSettings::Air::LicheWeightStrategic);
        _AddTier(4, array<string> = {"armgeo", "corgeo", "leggeo", "armuwgeo", "coruwgeo", "leguwgeo", "armgmm"},
            Global::RoleSettings::Air::LicheWeightGeo);
        _AddTier(5, UnitHelpers::GetAllGantries(), Global::RoleSettings::Air::LicheWeightGantry);
        _AddTier(6, array<string> = {"armaap", "armavp", "armalab", "armasy", "coraap", "coravp", "coralab", "corasy",
            "legaap", "legavp", "legalab", "legadvshipyard"}, Global::RoleSettings::Air::LicheWeightT2Factory);
        // Only statics take part in the in-flight handoff; check the tiers stay ordered there.
        tierMin.resize(7);
        array<float> tierMax(7);
        for (int t = 0; t < 7; ++t) { tierMin[t] = 0.0f; tierMax[t] = 0.0f; }
        int targets = 0;
        for (int i = 0; i < n; ++i) {
            const int t = tierByDef[i];
            if (t == 0) continue;
            ++targets;
            CCircuitDef@ d = ai.GetCircuitDef(i);
            if (d is null || d.IsMobile()) continue;
            if (tierMin[t] <= 0.0f || weightByDef[i] < tierMin[t]) tierMin[t] = weightByDef[i];
            if (weightByDef[i] > tierMax[t]) tierMax[t] = weightByDef[i];
        }
        for (int t = 1; t < 6; ++t)
            if (tierMin[t] > 0.0f && tierMax[t + 1] >= tierMin[t])
                GenericHelpers::LogUtil("[AIR][Liche] WARNING tier " + t + " lowest weight " + tierMin[t]
                    + " <= tier " + (t + 1) + " highest " + tierMax[t + 1] + ": raise the tier weights apart", 1);
        GenericHelpers::LogUtil("[AIR][Liche] roster targets=" + targets, 2);
    }
    // Handoff threshold while the run is on a target of `tier`: the lowest weight of the nearest tier
    // above it, so only a strictly higher tier takes over; a top-tier target keeps itself. A target of
    // unknown tier (0: its def was seen only between scans) is treated as top tier: the native picks the
    // best-weighted known target, so it is usually a shield, and only a shield may take over from it.
    float _Threshold(int tier)
    {
        if (tier <= 0) tier = 1;
        for (int t = tier - 1; t >= 1; --t) if (tierMin[t] > 0.0f) return tierMin[t];
        return tierMin[tier] > 0.0f ? tierMin[tier] : 1.0f;
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
     beyond the bomber wave's own escort. Returns the Liches launched.
     **************************************************************************/
    int LaunchWith(int spareFighters)
    {
        if (!Enabled()) return 0;
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
        AirWaves::ConfigureStrike(wt, liche, held, available);
        const float resistance = AirWaves::learnedResistance;
        wt.SetMissionPolicy(Global::RoleSettings::Air::StrikeCorridorPadding,
            Global::RoleSettings::Air::StrikeEdgeInset, Global::RoleSettings::Air::StrikeUnknownReserve + resistance - 1.0f,
            Global::RoleSettings::Air::StrikeRiskScale * resistance, Global::RoleSettings::Air::StrikeArmyReserve * resistance,
            Global::RoleSettings::Air::StrikeLocalAaReserve * resistance, Global::RoleSettings::Air::StrikeSynchronize);
        for (uint i = 0; i < AirWaves::failedRaidAims.length(); ++i)
            if (ai.frame < AirWaves::failedRaidUntil[i])
                wt.ExcludeStrikeRegion(AirWaves::failedRaidAims[i], Global::RoleSettings::Air::StrikeFailedRegionRadius);
        _Configure(wt);
        bool picked = wt.PickStrikeTarget(Global::Map::StartPos, 5, 0.0f, false);
        if (!picked) picked = wt.PickStrikeTarget(Global::Map::StartPos, 7, 0.0f, true);
        if (!picked) {
            if (ai.frame - lastHoldLog >= 30 * SECOND) {
                lastHoldLog = ai.frame;
                GenericHelpers::LogUtil("[AIR][Liche] held: no feasible tier target for " + available
                    + " Liche(s); fewest needed=" + wt.GetRequiredBombers(), 1);
            }
            raw.Abort();
            return 0;
        }
        // Spare payload is not wasted: after the first kill the run keeps descending the tiers.
        wt.AddTargetFallback(7); // mobile anti-nukes
        wt.AddTargetFallback(3); // turrets
        wt.AddTargetFallback(4); // other economy and support structures
        wt.AddTargetFallback(0); // remaining structures
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
        _Remember();
        const int tier = _TargetTier(wt.GetStrikeTargetId());
        _SetHandoff(wt, tier);
        GenericHelpers::LogUtil("[AIR][Liche] launched liches=" + cohort.getSize() + " escorts=" + escorts
            + " target=" + wt.GetStrikeTargetId() + " tier=" + tier + " required=" + wt.GetRequiredBombers()
            + " aim=" + int(wt.GetAim().x) + "," + int(wt.GetAim().z), 1);
        return int(cohort.getSize());
    }

    void _Configure(CAirWaveTask@ wt)
    {
        wt.SetOperationPolicy(true, 5, Global::Map::StartPos, Global::RoleSettings::Air::StrikeEscortLead,
            Global::RoleSettings::Air::StrikeBacklineRiskLimit, Global::RoleSettings::Air::StrikeDistrictRadius);
        for (int i = 0; i < int(weightByDef.length()); ++i)
            if (weightByDef[i] > 0.0f) wt.AllowStrikeDef(ai.GetCircuitDef(i), weightByDef[i]);
        array<AIFloat3> starts = Lanes::ScriptStarts(true);
        for (uint i = 0; i < starts.length(); ++i) wt.AddSearchPoint(starts[i]);
        if (starts.length() == 0) wt.AddSearchPoint(AirScreen::Enemy(Global::Map::StartPos));
    }
    void _SetHandoff(CAirWaveTask@ wt, int tier)
    {
        wt.SetAttackHandoffPolicy(Global::RoleSettings::Air::StrikeEarlyAttack, _Threshold(tier),
            Global::RoleSettings::Air::LicheImmediateRadius);
    }
    // Tier of an enemy by id, from the last time it was a ground contact; 0 when it is not a Liche
    // target or was never seen as one.
    int _TargetTier(int enemyId)
    {
        int64 tier = 0;
        if (enemyId < 0 || !seenTier.get("" + enemyId, tier)) return 0;
        return int(tier);
    }
    // A mobile anti-nuke keeps its tier too: the native keeps only a static target by itself,
    // but the threshold still decides which visible static may take over from it.
    int _Tier(int defId)
    {
        return (defId < 0 || defId >= int(tierByDef.length())) ? 0 : tierByDef[defId];
    }
    // One scan of the current ground contacts: remember the tier of every Liche target seen.
    void _Remember()
    {
        InitRoster();
        const int contacts = aiBattle.GetGroundContactCount();
        for (int i = 0; i < contacts; ++i) {
            const int tier = _Tier(aiBattle.GetGroundContactDefId(i));
            if (tier > 0) seenTier.set("" + aiBattle.GetGroundContactId(i), int64(tier));
        }
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
        _Remember();
        for (uint r = 0; r < runs.length(); ++r) {
            const int target = runs[r].GetStrikeTargetId();
            const int tier = _TargetTier(target);
            _SetHandoff(runs[r], tier);
            if (target * 8 + tier == runTarget[r]) continue;
            runTarget[r] = target * 8 + tier;
            GenericHelpers::LogUtil("[AIR][Liche] run target=" + target + " tier=" + tier
                + " handoff=" + _Threshold(tier), 1);
        }
    }

    void Removed(CCircuitUnit@ u) { if (u !is null) held.delete("" + u.id); }
    // AirProduction::Leave: held Liches return to native defaults; their staging tasks are aborted there.
    array<string>@ HeldIds() { return held.getKeys(); }
}  // namespace AirLiches
