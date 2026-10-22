#include "air_waves.as"
// T1 reusable bombers have a separate pool; Legion gunships use native raiding.
namespace AirRaids {
    dictionary held;
    dictionary joining;
    dictionary cohort;
    CAirWaveTask@ wave = null;
    int lastTry = -100000;
    int lastLaunch = -100000;
    bool OpeningPending() { return Global::RoleSettings::Air::T1OpeningRaidEnabled && aiTerrainMgr.GetLayoutInt("air.t1.openingDone", 0) == 0; }
    int OpeningSize()
    {
        int size = aiTerrainMgr.GetLayoutInt("air.t1.openingSize", 0);
        if (size <= 0) {
            const int low = AirMath::OpeningWave(Global::RoleSettings::Air::T1OpeningBomberMin, Global::RoleSettings::Air::T1OpeningBomberMax, 0);
            const int high = AirMath::OpeningWave(Global::RoleSettings::Air::T1OpeningBomberMin, Global::RoleSettings::Air::T1OpeningBomberMax, 300);
            size = AiRandom(low, high);
            aiTerrainMgr.SetLayoutInt("air.t1.openingSize", size);
            GenericHelpers::LogUtil("[AIR][Raid] opening size drawn=" + size, 1);
        }
        return size;
    }
    bool IsBomber(const CCircuitDef@ d)
    {
        return d !is null && (d.GetName() == "armthund" || d.GetName() == "corshad");
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u)
    {
        if (!AirEconomy::Active() || u is null) return null;
        // Generic DEFEND waits for armed enemy groups and misses exposed eco.
        // Reuse the threat-aware raider's full enemy scan for this light gunship.
        if (u.circuitDef.GetName() == "legmos") return aiMilitaryMgr.Enqueue(TaskF::Common(Task::FightType::RAID));
        if (!IsBomber(u.circuitDef)) return null;
        const string key = "" + u.id;
        if (joining.exists(key)) {
            joining.delete(key);
            if (wave !is null && !wave.IsDead()) return wave;
        }
        IUnitTask@ stage = AirWaves::StagingTask(u, true);
        if (stage !is null) held.set(key, true);
        return stage;
    }
    void Update()
    {
        if (!AirEconomy::Active() || ai.frame - lastTry < 10 * SECOND) return;
        lastTry = ai.frame;
        // Actual defensive ownership removes members from held. Do not veto
        // unrelated reserves merely because another unit is defending land.
        if (wave !is null && !wave.IsDead()
            && ai.frame-lastLaunch < AiMax(1, Global::RoleSettings::Air::StrikeCadenceSeconds)*SECOND) return;
        if (wave !is null) {
            int survivors = 0;
            array<string>@ ids = cohort.getKeys();
            for (uint i = 0; i < ids.length(); ++i) if (ai.GetTeamUnit(parseInt(ids[i])) !is null) ++survivors;
            GenericHelpers::LogUtil("[AIR][Raid] previous cohort=" + cohort.getSize() + " survivors=" + survivors
                + " committed=" + !wave.IsDead(), 1);
            cohort.deleteAll(); joining.deleteAll(); @wave = null;
        }
        if (OpeningPending() && aiTerrainMgr.GetLayoutInt("air.t1.openingReady", 0) == 0) return;
        array<string>@ candidates = held.getKeys();
        for (uint i = 0; i < candidates.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(candidates[i]));
            if (u is null || (u.task !is null && u.task.GetType() == int(Task::Type::PLAYER))) held.delete(candidates[i]);
        }
        const int minimum = OpeningPending() ? OpeningSize() : Global::RoleSettings::Air::T1RaidMinimum;
        if (int(held.getSize()) < minimum
            || AirOperations::AvailableFighters(true) < AirEconomy::EnemyAir()) return;
        array<string>@ ids = held.getKeys();
        CCircuitUnit@ first = ai.GetTeamUnit(parseInt(ids[0]));
        if (first is null) { held.delete(ids[0]); return; }
        @wave = cast<CAirWaveTask>(aiMilitaryMgr.Enqueue(TaskF::Wave()));
        if (wave is null) return;
        AirWaves::ConfigureStrike(wave, ai.GetCircuitDef(first.circuitDef.GetName()), held);
        wave.SetMissionPolicy(Global::RoleSettings::Air::StrikeCorridorPadding,
            Global::RoleSettings::Air::StrikeEdgeInset, Global::RoleSettings::Air::StrikeUnknownReserve,
            Global::RoleSettings::Air::StrikeRiskScale, Global::RoleSettings::Air::StrikeArmyReserve,
            Global::RoleSettings::Air::StrikeLocalAaReserve, false);
        AirOperations::Configure(wave, true, 2);
        if (!wave.PickOperationTarget(Global::Map::StartPos, 0.0f)) {
            wave.Abort(); @wave = null; return;
        }
        wave.SetPlan(Task::WaveMode::STRIKE, wave.GetAim(), Global::RoleSettings::Air::WaveFormDistance,
            Global::RoleSettings::Air::StrikeLaneSpacing, Global::RoleSettings::Air::WaveOverrun,
            Global::RoleSettings::Air::WaveFormTimeoutSeconds * SECOND, 0, Task::WAVE_SMART_BEARING, 1);
        array<IUnitTask@> tasks;
        for (uint i = 0; i < ids.length() && (!OpeningPending() || int(cohort.getSize()) < minimum); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u is null) continue;
            if (aiMilitaryMgr.TransferUnit(u, wave)) { cohort.set(ids[i], true); held.delete(ids[i]); }
        }
        if (cohort.isEmpty()) { wave.Abort(); @wave = null; return; }
        if (OpeningPending()) {
            if (int(cohort.getSize()) != minimum) Invariants::Violation("INV-122", "T1 opening", "opening raid did not transfer its drawn cohort");
            aiTerrainMgr.SetLayoutInt("air.t1.openingDone", 1);
        }
        const int escorts = AirOperations::AttachFighters(wave);
        AirOperations::TrackBombers(wave, cohort); lastLaunch = ai.frame;
        GenericHelpers::LogUtil("[AIR][Raid] launched bombers=" + cohort.getSize() + " escorts=" + escorts + " target=" + wave.GetStrikeTargetId(), 1);
    }
    void Removed(int id) { held.delete("" + id); joining.delete("" + id); }
    void Reset()
    {
        array<string>@ ids = held.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null) {
                u.SetFireState(u.circuitDef.GetFireState()); u.SetIdleMode(1);
                if (u.task !is null) u.task.Abort();
            }
        }
        if (wave !is null && !wave.IsDead()) wave.Abort();
        @wave = null; held.deleteAll(); joining.deleteAll(); cohort.deleteAll(); lastTry = -100000; lastLaunch = -100000;
    }
}
