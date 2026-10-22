// D-291: post-wipe escort reconnaissance. When every bomber launched by an
// offensive AIR operation (T2 wave or T1 raid) is dead, the operation's
// surviving escort fighters (T1 and T2, only those that were escorting) fan
// out beyond the enemy base to scout, then return to the home screen.
//
// Ownership: fighter IDs only. Each scout gets its own CRouteTask (managed
// control, single leg); handles are checked with IsDead() before use and the
// route aborts itself when its last unit leaves (AirBaseResponse pre-emption,
// a new operation's CanEscort transfer, death).
//
// Callback contract: Plan() runs inside the native TaskRemoved callback of the
// dying wave (TaskModule::DequeueTask: Dead -> TaskRemoved -> Stop), so it only
// records points; it never enqueues, aborts or orders there. The fighters go
// idle when the wave stops and re-enter Air_MilitaryAiMakeTask, where TaskFor
// hands each its route.
//
// Cost: Plan is once per wiped offensive operation (minutes apart per AI):
// one O(n log n) sort plus at most 9 candidates x 2 AirThreatAlong corridor
// queries per fighter (n <= EscortScoutMax) and an O(n^2) spacing check on the
// chosen points. Tick is O(active + pending) per policy tick and returns at
// once when both are empty. Commands: one route leg per scout at Start and one
// Abort (which leads to the home-screen order the fighter would get anyway).
// Not persisted (like other AIR operation membership): after a load the
// survivors simply return home. Regression: cases/air/combat/escort-scout-wipe.json.
namespace AirEscortScout {
    dictionary pending;   // fighter id -> index into points
    dictionary pendingAt; // fighter id -> int64 frame planned
    dictionary active;    // fighter id -> CRouteTask@
    dictionary startedAt; // fighter id -> int64 frame dispatched
    dictionary arrivedAt; // fighter id -> int64 frame first seen at its point
    array<AIFloat3> points;
    const array<float> nudge = {0.0f, 0.5f, -0.5f, 1.0f, -1.0f, 1.5f, -1.5f, 2.0f, -2.0f}; // candidate offsets in fan steps

    AIFloat3 Rotate(const AIFloat3 &in d, float a)
    {
        return AIFloat3(d.x * cos(a) - d.z * sin(a), 0.0f, d.x * sin(a) + d.z * cos(a));
    }
    // A candidate must lie inside the map with the screen margin; clamping an
    // off-map point onto the edge stacks the whole fan on one line.
    bool Inside(const AIFloat3 &in p)
    {
        return p.x >= 128.0f && p.z >= 128.0f && p.x <= float(AiTerrainWidth()) - 128.0f && p.z <= float(AiTerrainHeight()) - 128.0f;
    }
    // Primary enemy base: the start nearest the operation's aim; further bases
    // follow by distance from it (deterministic for a given start list). Script
    // starts of every foreign ally team count as enemy (SetupManager), which in
    // a fixture includes spectator and gaia placeholders at the map corner, so
    // a start within the screen margin of the edge is dropped unless it is all
    // there is.
    array<AIFloat3>@ Bases(const AIFloat3 &in aim)
    {
        array<AIFloat3> all = Lanes::ScriptStarts(true);
        if (all.length() == 0) all.insertLast(AirScreen::Enemy(Global::Map::StartPos));
        array<AIFloat3> starts;
        for (uint i = 0; i < all.length(); ++i) if (Inside(all[i])) starts.insertLast(all[i]);
        if (starts.length() == 0) starts = all;
        uint first = 0;
        for (uint i = 1; i < starts.length(); ++i)
            if (MapHelpers::SqDist(aim, starts[i]) < MapHelpers::SqDist(aim, starts[first])) first = i;
        array<AIFloat3> result = {starts[first]};
        starts.removeAt(first);
        while (starts.length() > 0) {
            uint next = 0;
            for (uint i = 1; i < starts.length(); ++i)
                if (MapHelpers::SqDist(result[0], starts[i]) < MapHelpers::SqDist(result[0], starts[next])) next = i;
            result.insertLast(starts[next]);
            starts.removeAt(next);
        }
        return result;
    }
    // Leg exposure. aiBattle.AirThreatAlong returns the highest threat-map cell
    // the padded corridor touches (threat-grid units, the scale of
    // NavalSupportMaxThreat and StrikeMaxThreat), and only below 1.0 falls back
    // to "a visible SurfToAir range intersects" (returns 1.0). Fighters start
    // inside the umbrella that killed the bombers, so every leg crosses it;
    // judge only the part beyond EscortScoutExitDistance. Hidden AA is unseen:
    // advisory, not a safety guarantee.
    float LegRisk(const AIFloat3 &in from, const AIFloat3 &in p)
    {
        const float sq = MapHelpers::SqDist(from, p);
        const float exit = Global::RoleSettings::Air::EscortScoutExitDistance;
        AIFloat3 q = from;
        if (sq > exit * exit) {
            const float f = exit / sqrt(sq);
            q = AIFloat3(from.x + (p.x - from.x) * f, 0.0f, from.z + (p.z - from.z) * f);
        }
        return aiBattle.AirThreatAlong(q, p, Global::RoleSettings::Air::EscortScoutThreatPadding);
    }
    // Destination exposure: the threat cell at the point, or 1.0 when a visible
    // AA range covers it. A scout never parks under known AA.
    float PointRisk(const AIFloat3 &in p)
    {
        return aiBattle.AirThreatAlong(p, p, Global::RoleSettings::Air::EscortScoutThreatPadding);
    }
    void Plan(CAirWaveTask@ wave, array<int>@ fighters, int op)
    {
        if (!Global::RoleSettings::Air::EscortScoutEnabled || wave is null || fighters is null || fighters.length() == 0) return;
        fighters.sortAsc(); // stable allocation independent of native member order
        const int cap = AiMin(int(fighters.length()), AiMax(0, Global::RoleSettings::Air::EscortScoutMax));
        array<AIFloat3>@ bases = Bases(wave.GetAim());
        const AIFloat3 home = Global::Map::StartPos;
        const float minSp = Global::RoleSettings::Air::EscortScoutMinSpacing;
        const int perBase = AiMax(1, Global::RoleSettings::Air::EscortScoutPerBase);
        const float half = Global::RoleSettings::Air::EscortScoutFanDegrees * 0.5f * 0.0174533f;
        const float step = perBase > 1 ? 2.0f * half / float(perBase - 1) : 0.0f;
        array<AIFloat3> chosen;
        int skippedAa = 0, skippedLeg = 0, skippedSite = 0;
        IUnitTask@ waveTask = cast<IUnitTask>(wave);
        for (int i = 0; i < cap; ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(fighters[i]);
            if (u is null) continue;
            IUnitTask@ owner;
            if (!AirOperations::escorts.get("" + fighters[i], @owner) || owner !is waveTask)
                Invariants::Violation("INV-202", "" + fighters[i], "escort scout planned for a fighter that did not escort the wiped operation");
            const AIFloat3 from = u.GetPos(ai.frame);
            const AIFloat3 base = bases[uint(i / perBase) % bases.length()];
            AIFloat3 axis(base.x - home.x, 0.0f, base.z - home.z); // our base -> their base -> their rear
            const float len = sqrt(axis.x * axis.x + axis.z * axis.z);
            axis = len < 1.0f ? AIFloat3(1.0f, 0.0f, 0.0f) : AIFloat3(axis.x / len, 0.0f, axis.z / len);
            const int slot = i % perBase;
            const int layer = i / (perBase * int(bases.length()));
            const float radius = Global::RoleSettings::Air::EscortScoutDepth
                + float(layer) * Global::RoleSettings::Air::EscortScoutLayerStep;
            AIFloat3 best;
            float bestRisk = 1.0e30f, bestLeg = 0.0f, bestPoint = 0.0f;
            bool found = false, aaOnly = false;
            // Nudges up to two fan steps either way let a base near the map
            // edge, whose rear is off the map, still use its in-map flanks.
            for (uint k = 0; k < nudge.length(); ++k) {
                const AIFloat3 d = Rotate(axis, -half + step * float(slot) + nudge[k] * step);
                const AIFloat3 p(base.x + d.x * radius, 0.0f, base.z + d.z * radius);
                if (!Inside(p)) continue;
                bool crowded = false;
                for (uint c = 0; c < chosen.length() && !crowded; ++c)
                    crowded = MapHelpers::SqDist(p, chosen[c]) < minSp * minSp;
                if (crowded) continue;
                const float point = PointRisk(p);
                const float leg = LegRisk(from, p);
                if (!AirMath::Valid(point) || !AirMath::Valid(leg)) continue;
                if (point >= Global::RoleSettings::Air::EscortScoutMaxThreat) { aaOnly = true; continue; }
                const float risk = leg + point;
                if (risk < bestRisk) { bestRisk = risk; bestLeg = leg; bestPoint = point; best = p; found = true; }
                if (risk <= Global::RoleSettings::Air::EscortScoutSafeThreat) break;
            }
            if (found && bestLeg >= Global::RoleSettings::Air::EscortScoutMaxLegThreat) {
                ++skippedLeg;
                GenericHelpers::LogUtil("[AIR][EscortScout] skip fighter=" + fighters[i] + " op=" + op + " reason=leg risk=" + bestLeg, 1);
                continue;
            }
            if (!found) {
                if (aaOnly) ++skippedAa; else ++skippedSite;
                GenericHelpers::LogUtil("[AIR][EscortScout] skip fighter=" + fighters[i] + " op=" + op
                    + " reason=" + (aaOnly ? "aa" : "no spaced site"), 1);
                continue; // idles into AirProduction::HomeTask as before
            }
            chosen.insertLast(best);
            const string key = "" + fighters[i];
            pending.set(key, int(points.length()));
            pendingAt.set(key, int64(ai.frame));
            points.insertLast(best);
            GenericHelpers::LogUtil("[AIR][EscortScout] fighter=" + fighters[i] + " def=" + u.circuitDef.GetName()
                + " op=" + op + " point=" + int(best.x) + "," + int(best.z) + " slot=" + i + "/" + cap
                + " leg=" + bestLeg + " point=" + bestPoint, 1);
        }
        // INV-202 spacing, O(n^2) with n <= EscortScoutMax, once per wipe.
        for (uint a = 0; a < chosen.length(); ++a)
            for (uint b = a + 1; b < chosen.length(); ++b)
                if (MapHelpers::SqDist(chosen[a], chosen[b]) < minSp * minSp)
                    Invariants::Violation("INV-202", "op " + op, "escort scout points of one wipe are closer than EscortScoutMinSpacing");
        GenericHelpers::LogUtil("[AIR][EscortScout] plan op=" + op + " anchor=" + int(bases[0].x) + "," + int(bases[0].z)
            + " bases=" + bases.length() + " fighters=" + fighters.length() + " points=" + chosen.length()
            + " rejected=" + (skippedAa + skippedLeg + skippedSite) + " aa=" + skippedAa + " leg=" + skippedLeg
            + " site=" + skippedSite + " homeward=" + (int(fighters.length()) - cap), 1);
    }
    // Air_MilitaryAiMakeTask hook, after AirBaseResponse (home emergencies keep
    // priority) and before AirRecon/HomeTask. Returns null for every fighter
    // without a live plan, so the cost for ordinary idles is one lookup.
    IUnitTask@ TaskFor(CCircuitUnit@ u)
    {
        if (u is null || (active.isEmpty() && pending.isEmpty())) return null;
        const string key = "" + u.id;
        CRouteTask@ live;
        if (active.get(key, @live) && live !is null && !live.IsDead()) return live; // idle re-entry mid-route
        int index = -1;
        int64 at = 0;
        if (!pending.get(key, index)) return null;
        pendingAt.get(key, at);
        pending.delete(key); pendingAt.delete(key);
        if (ai.frame - at > Global::RoleSettings::Air::EscortScoutPendingSeconds * SECOND
            || !AirScreen::IsFighter(u.circuitDef) || index < 0 || index >= int(points.length())) return null;
        CRouteTask@ r = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (r is null) return null;
        array<AIFloat3> route = {points[index]};
        r.SetAirControl(true); r.SetPatrol(false);
        u.SetIdleMode(0); u.SetFireState(2);
        r.SetRoute(route);
        active.set(key, @r);
        startedAt.set(key, int64(ai.frame));
        GenericHelpers::LogUtil("[AIR][EscortScout] dispatch fighter=" + u.id + " point=" + int(points[index].x) + "," + int(points[index].z), 1);
        return r;
    }
    void Forget(const string &in key)
    {
        active.delete(key); startedAt.delete(key); arrivedAt.delete(key);
    }
    void Release(const string &in key, CRouteTask@ r, const string &in why)
    {
        Forget(key);
        if (r !is null && !r.IsDead()) r.Abort(); // fighter idles -> HomeTask -> AirScreen
        GenericHelpers::LogUtil("[AIR][EscortScout] released fighter=" + key + " reason=" + why, 1);
    }
    // Policy tick (AirOperations::Tick). Arrival, timeout and pre-emption.
    void Tick()
    {
        if (active.isEmpty() && pending.isEmpty()) {
            if (points.length() > 0) points.resize(0);
            return;
        }
        const int timeout = Global::RoleSettings::Air::EscortScoutTimeoutSeconds * SECOND;
        array<string>@ ids = active.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CRouteTask@ r;
            active.get(ids[i], @r);
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            int64 t0 = 0;
            startedAt.get(ids[i], t0);
            if (u is null) { Forget(ids[i]); continue; } // died while scouting
            if (r is null || r.IsDead() || u.task !is r) { Release(ids[i], null, "reassigned"); continue; }
            // INV-202: a scout route never outlives its timeout by more than a tick of grace.
            if (ai.frame - t0 > timeout + 2 * SECOND)
                Invariants::Violation("INV-202", ids[i], "escort scout route outlived EscortScoutTimeoutSeconds");
            int64 arrived = -1;
            if (!arrivedAt.get(ids[i], arrived) && r.IsAtEnd(u)) {
                arrived = ai.frame;
                arrivedAt.set(ids[i], arrived);
            }
            if (arrived >= 0 && ai.frame - arrived >= Global::RoleSettings::Air::EscortScoutLingerSeconds * SECOND)
                Release(ids[i], r, "arrived");
            else if (ai.frame - t0 > timeout)
                Release(ids[i], r, "timeout");
        }
        // Expire stale plans (fighter re-tasked before it idled).
        array<string>@ p = pendingAt.getKeys();
        for (uint i = 0; i < p.length(); ++i) {
            int64 at = 0;
            pendingAt.get(p[i], at);
            if (ai.frame - at > Global::RoleSettings::Air::EscortScoutPendingSeconds * SECOND) {
                pending.delete(p[i]); pendingAt.delete(p[i]);
                GenericHelpers::LogUtil("[AIR][EscortScout] expired plan fighter=" + p[i], 1);
            }
        }
    }
    void Reset()
    {
        array<string>@ ids = active.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CRouteTask@ r;
            active.get(ids[i], @r);
            if (r !is null && !r.IsDead()) r.Abort();
        }
        active.deleteAll(); startedAt.deleteAll(); arrivedAt.deleteAll();
        pending.deleteAll(); pendingAt.deleteAll(); points.resize(0);
    }
}
