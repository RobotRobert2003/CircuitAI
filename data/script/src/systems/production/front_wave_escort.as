// Owner (2026-10-20): the escorts are queued before the tanks and the wave's gather holds (FrontOpener::
// RequiredPower) until every queued escort is out or the gather deadline passes, so the group leaves together.
// Owner (2026-10-19): every T2 vehicle tank wave (FrontTankMass T2 tier: Bull/Tiger/Prometheus)
// gets its own escort from the same T2 vehicle plant: a radar jammer, a radar vehicle and a flak
// vehicle (Armada Sneaky Pete/Seer/Shredder, Cortex Deceiver/Informant/Fury, Legion
// legavjam/legavrad/Charon). The wave's tanks are enumerated as they come out of the plant; the
// escorts sit on one route task that is moved to the wave's safe centre: the centroid of its
// living tanks, pulled WaveEscortBehind back toward our start so the escorts trail the attack
// instead of leading it. Before the first tank is out the centre is the plant. When the wave's
// last tank dies the route is aborted and the escorts go back to ordinary military orders.
// Hooks: FrontTankMass::Roll (Begin), Front military UnitAdded/MakeTask/UnitRemoved/TaskRemoved,
// AiUpdate (Update, throttled). Log [FRONT][WaveEscort].
namespace FrontWaveEscort {
    class Wave {
        int id;
        int factoryId;
        int tankDefId;
        int expected;         // tanks rolled for this wave
        int started;          // frame of the roll; units produced earlier never join
        int deadline;         // no tank out by now and nothing to escort: drop the wave
        array<int> tanks;     // the wave's members, enumerated as they are admitted
        array<int> escortDefs;   // escort slots still to fill (def ids)
        array<IUnitTask@> recruits;   // the escorts' factory recruit tasks, parallel to recruitDefs
        array<int> recruitDefs;
        array<int> escorts;      // escort unit ids
        CRouteTask@ route;
        AIFloat3 target;
        bool routed;
        bool hadTank;
        int nextMoveLog;   // throttles the escort move line to one per 20 s
    }
    array<Wave@> waves;
    int nextWaveId = 1;
    int nextUpdate = 0;

    bool Enabled() { return Global::RoleSettings::Front::VehicleT2WaveEscorts; }

    array<string> EscortNames(const string &in side) {
        if (side == "armada") return array<string> = {"armjam", "armseer", "armyork"};       // Sneaky Pete, Seer, Shredder
        if (side == "cortex") return array<string> = {"coreter", "corvrad", "corsent"};     // Deceiver, Informant, Fury
        if (side == "legion") return array<string> = {"legavjam", "legavrad", "legvflak"};  // jammer, radar, Charon
        return array<string> = {};
    }

    // FrontTankMass T2 roll hit: count tanks of tankDef are about to be queued at factory u. Queue the escorts
    // first; returns the first escort's recruit task (the factory's next build), null without escorts.
    IUnitTask@ Begin(CCircuitUnit@ u, const string &in side, CCircuitDef@ tankDef, int count, int gatherSeconds) {
        if (!Enabled() || u is null || tankDef is null) return null;
        Wave@ w = Wave();
        w.routed = false; w.hadTank = false; w.nextMoveLog = 0;
        w.id = nextWaveId++;
        w.factoryId = u.id; w.tankDefId = tankDef.id; w.expected = count;
        w.started = ai.frame;
        w.deadline = ai.frame + AiMax(1, gatherSeconds) * SECOND;
        w.target = u.GetPos(ai.frame);
        const array<string> names = EscortNames(side);
        string queued = "";
        IUnitTask@ first = null;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(names[i]);
            if (def is null || !u.circuitDef.CanBuild(def) || !def.IsAvailable(ai.frame)) {
                GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": no '" + names[i] + "' at " + u.circuitDef.GetName(), 1);
                continue;
            }
            IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, def, w.target, 64.f));
            if (r is null) continue;
            if (first is null) @first = r;
            w.escortDefs.insertLast(def.id);
            w.recruits.insertLast(r); w.recruitDefs.insertLast(def.id);
            queued += (queued == "" ? "" : ", ") + names[i];
        }
        waves.insertLast(w);
        GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": " + count + " x " + tankDef.GetName()
            + " at factory " + u.id + ", escorts queued: " + (queued == "" ? "none" : queued), 1);
        return first;
    }

    // The gather of factory's batch started at frame `started` still waits for escorts of its wave
    bool Pending(int factoryId, int started) {
        if (!Enabled()) return false;
        for (uint i = 0; i < waves.length(); ++i)
            if (waves[i].factoryId == factoryId && waves[i].started == started) return waves[i].escortDefs.length() > 0;
        return false;
    }

    bool Produced(CCircuitUnit@ unit, Wave@ w) {
        return unit.GetProductionFrame() >= w.started;
    }

    // Military UnitAdded: enumerate a wave tank or claim an escort slot
    void UnitAdded(CCircuitUnit@ unit) {
        if (unit is null || unit.circuitDef is null || waves.length() == 0) return;
        const int defId = unit.circuitDef.id;
        for (uint i = 0; i < waves.length(); ++i) {
            Wave@ w = waves[i];
            if (w.tanks.find(unit.id) >= 0 || w.escorts.find(unit.id) >= 0) return;
            if (defId == w.tankDefId && unit.GetProducerId() == w.factoryId && Produced(unit, w)
                && int(w.tanks.length()) < w.expected) {
                w.tanks.insertLast(unit.id); w.hadTank = true;
                GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": tank " + w.tanks.length() + "/" + w.expected
                    + " " + unit.circuitDef.GetName() + " " + unit.id, 1);
                return;
            }
            const int slot = w.escortDefs.find(defId);
            if (slot >= 0 && Produced(unit, w)) {
                w.escortDefs.removeAt(slot);
                w.escorts.insertLast(unit.id);
                GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": escort " + unit.circuitDef.GetName() + " " + unit.id
                    + " assigned" + (w.escortDefs.length() == 0 ? "; all escorts out, the wave may depart" : ""), 1);
                if (w.escortDefs.length() == 0) FrontOpener::RefreshPower();
                return;
            }
        }
    }

    Wave@ EscortWave(int unitId) {
        for (uint i = 0; i < waves.length(); ++i)
            if (waves[i].escorts.find(unitId) >= 0) return waves[i];
        return null;
    }

    // Military MakeTask: an escort rides its wave's route task
    IUnitTask@ MilitaryTask(CCircuitUnit@ unit) {
        if (unit is null) return null;
        Wave@ w = EscortWave(unit.id);
        if (w is null) return null;
        if (w.route is null || w.route.IsDead()) {
            @w.route = cast<CRouteTask>(cast<IFighterTask>(aiMilitaryMgr.Enqueue(TaskF::Route())));
            if (w.route is null) return null;
            w.route.SetTraversal(false, 96.0f, false);
            w.routed = false;
        }
        if (!w.routed) {
            const array<AIFloat3> points = {w.target};
            w.route.SetRoute(points);
            w.routed = true;
        }
        return w.route;
    }

    void Release(uint index, const string &in why) {
        Wave@ w = waves[index];
        waves.removeAt(index);   // before Abort: its idle escorts must not find the wave again
        GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + " " + why + ": " + w.escorts.length()
            + " escort(s) back to normal orders", 1);
        if (w.route !is null && !w.route.IsDead()) w.route.Abort();
        @w.route = null;
    }

    void UnitRemoved(CCircuitUnit@ unit) {
        if (unit is null) return;
        for (uint i = 0; i < waves.length(); ++i) {
            Wave@ w = waves[i];
            int k = w.tanks.find(unit.id);
            if (k >= 0) { w.tanks.removeAt(k); return; }
            k = w.escorts.find(unit.id);
            if (k >= 0) { w.escorts.removeAt(k); return; }
        }
    }

    // Factory TaskRemoved: an escort's recruit dropped without its unit finishing frees that slot, so the
    // wave stops waiting for it and never claims a later wave's escort for it (owner, 2026-10-20)
    void RecruitRemoved(IUnitTask@ task, bool done) {
        for (uint i = 0; i < waves.length(); ++i) {
            Wave@ w = waves[i];
            for (uint k = 0; k < w.recruits.length(); ++k) {
                if (w.recruits[k] !is task) continue;
                const int defId = w.recruitDefs[k];
                w.recruits.removeAt(k); w.recruitDefs.removeAt(k);
                if (done) return;
                const int slot = w.escortDefs.find(defId);
                if (slot < 0) return;
                w.escortDefs.removeAt(slot);
                GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": escort order (def " + defId + ")"
                    + " dropped unbuilt; slot freed" + (w.escortDefs.length() == 0 ? ", the wave may depart" : ""), 1);
                if (w.escortDefs.length() == 0) FrontOpener::RefreshPower();
                return;
            }
        }
    }

    void TaskRemoved(IUnitTask@ task) {
        for (uint i = 0; i < waves.length(); ++i)
            if (waves[i].route !is null && cast<IUnitTask>(waves[i].route) is task) { @waves[i].route = null; waves[i].routed = false; }
    }

    // The wave's safe centre: the centroid of its living tanks, WaveEscortBehind back toward our start
    bool SafeCentre(Wave@ w, AIFloat3 &out centre) {
        float sx = 0.0f, sz = 0.0f; int n = 0;
        for (uint i = 0; i < w.tanks.length(); ++i) {
            CCircuitUnit@ t = ai.GetTeamUnit(w.tanks[i]);
            if (t is null) continue;
            const AIFloat3 p = t.GetPos(ai.frame);
            sx += p.x; sz += p.z; ++n;
        }
        if (n == 0) return false;
        float x = sx / float(n), z = sz / float(n);
        float dx = Global::Map::StartPos.x - x, dz = Global::Map::StartPos.z - z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len > 1.0f) {
            const float back = AiMin(Global::RoleSettings::Front::WaveEscortBehind, len * 0.5f);
            x += dx / len * back; z += dz / len * back;
        }
        const float m = 64.0f;
        x = AiMax(m, AiMin(float(AiTerrainWidth()) - m, x));
        z = AiMax(m, AiMin(float(AiTerrainHeight()) - m, z));
        centre = AIFloat3(x, 0.0f, z);
        return true;
    }

    // AiUpdate: follow each wave's attack, drop finished waves
    void Update() {
        if (waves.length() == 0 || ai.frame < nextUpdate) return;
        nextUpdate = ai.frame + AiMax(1, Global::RoleSettings::Front::WaveEscortUpdateSeconds) * SECOND;
        const float repath = Global::RoleSettings::Front::WaveEscortRepath;
        for (int i = int(waves.length()) - 1; i >= 0; --i) {
            Wave@ w = waves[i];
            // Departed (its gather closed) with slots still open: stop claiming, a later wave's escort is not ours
            if (w.hadTank && w.escortDefs.length() > 0 && (FrontOpener::closed || FrontOpener::started != w.started)) {
                GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + " departed without " + w.escortDefs.length()
                    + " escort(s); slots closed", 1);
                w.escortDefs.resize(0);
            }
            AIFloat3 centre;
            if (!SafeCentre(w, centre)) {
                if (w.hadTank) { Release(i, "lost its last tank"); continue; }
                if (ai.frame >= w.deadline) { Release(i, "had no tank by its deadline"); continue; }
                continue;   // still gathering: the escorts wait at the plant
            }
            if (w.hadTank && w.escorts.length() == 0 && w.escortDefs.length() == 0) {
                Release(i, "lost every escort"); continue;
            }
            if (MapHelpers::SqDist(centre, w.target) < repath * repath) continue;
            w.target = centre;
            if (w.route !is null && !w.route.IsDead()) {
                const array<AIFloat3> points = {centre};
                w.route.SetRoute(points);
                w.routed = true;
                if (ai.frame >= w.nextMoveLog) {
                    w.nextMoveLog = ai.frame + 20 * SECOND;
                    GenericHelpers::LogUtil("[FRONT][WaveEscort] wave " + w.id + ": " + w.escorts.length() + " escort(s) to ("
                        + int(centre.x) + ", " + int(centre.z) + "), " + w.tanks.length() + " tank(s) alive", 1);
                }
            } else w.routed = false;
        }
    }

    void Load() {
        // Native route tasks are ephemeral across load; the escorts rejoin ordinary military policy
        for (int i = int(waves.length()) - 1; i >= 0; --i) Release(i, "reset on load");
        nextUpdate = 0;
    }
}
