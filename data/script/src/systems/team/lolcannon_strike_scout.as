// Strike scouting (owner 2026-10-27). A lolcannon keeps firing at what it last
// saw; a structure it destroyed in the fog stays on its target list until our
// sight covers the spot again (CMapManager::HostileInLOS drops a ghost then).
// So the cannon's highest-rated area (CSuperTask::GetTierAreaPos(0), in range,
// best target first) is scouted: StrikeRadarScouts T2 radar planes and
// StrikeT1Scouts T1 scouts, each to its own point round the area and on to the
// map edge beyond it (the far side, seen from the cannon).
//
// The cannon's side (FRONT or TECH) asks the allied AIR; with no AIR, this AI
// when it is TECH, else a TECH ally. Asked when the best area first appears,
// when it moves more than FireAreaRadius, and every StrikeScoutSeconds while the
// cannon has targets. The scouting side keeps one squad: the living members are
// sent again on each request, and only the missing ones are built.
//
//     lolcannon|strike|x|z|beyondX|beyondZ|radar|t1
namespace LolCannonStrikeScout {
    const string PREFIX = "lolcannon|strike|";

    // ------------------------------------------------------------ the cannon's side
    array<int> cannonIds;
    array<AIFloat3> askedPos;
    array<int> askedAt;
    int nextCheck = 0;

    void Watch(CCircuitUnit@ u)
    {
        if (u is null || cannonIds.find(u.id) >= 0) return;
        cannonIds.insertLast(u.id);
        askedPos.insertLast(AIFloat3(-1.0f, 0.0f, -1.0f));
        askedAt.insertLast(-1000000);
    }

    AIFloat3 Clamp(const AIFloat3 &in p)
    {
        const float m = 128.0f;
        return AIFloat3(AiMax(m, AiMin(float(AiTerrainWidth()) - m, p.x)), 0.0f, AiMax(m, AiMin(float(AiTerrainHeight()) - m, p.z)));
    }

    // the map edge beyond `target`, seen from `from`
    AIFloat3 Beyond(const AIFloat3 &in from, const AIFloat3 &in target)
    {
        float dx = target.x - from.x, dz = target.z - from.z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return Clamp(target);
        dx /= len; dz /= len;
        return Clamp(AIFloat3(target.x + dx * AirRecon::Extent(target, dx, dz), 0.0f, target.z + dz * AirRecon::Extent(target, dx, dz)));
    }

    int Provider(string &out who)
    {
        array<Team::Roster::Entry@>@ air = Team::Roster::WithRole(AiRole::AIR);
        int best = -1;
        for (uint i = 0; i < air.length(); ++i) if (best < 0 || air[i].teamId < best) best = air[i].teamId;
        if (best >= 0) { who = "AIR"; return best; }
        if (Global::AISettings::Role == AiRole::TECH) { who = "TECH (this AI, no AIR on the map)"; return ai.teamId; }
        array<Team::Roster::Entry@>@ tech = Team::Roster::WithRole(AiRole::TECH);
        for (uint i = 0; i < tech.length(); ++i) if (best < 0 || tech[i].teamId < best) best = tech[i].teamId;
        if (best >= 0) { who = "TECH (no AIR on the map)"; return best; }
        who = "none";
        return -1;
    }

    void Ask(CCircuitUnit@ cannon, const AIFloat3 &in top, int targetId, const string &in why)
    {
        const AIFloat3 from = cannon.GetPos(ai.frame);
        const AIFloat3 beyond = Beyond(from, top);
        const int radar = Global::LolCannon::StrikeRadarScouts, t1 = Global::LolCannon::StrikeT1Scouts;
        string who;
        const int provider = Provider(who);
        if (provider < 0) {
            GenericHelpers::LogUtil("[LolCannon] strike scout of (" + int(top.x) + ", " + int(top.z) + "): no AIR or TECH ally to fly it", 1);
            return;
        }
        GenericHelpers::LogUtil("[LolCannon] strike scout asked of " + who + "=" + provider + " (" + why + "): "
            + cannon.circuitDef.GetName() + " " + cannon.id + "'s highest-rated area at (" + int(top.x) + ", " + int(top.z)
            + "), target " + targetId + ", first waypoint (" + int(top.x) + ", " + int(top.z) + "), then to the edge at ("
            + int(beyond.x) + ", " + int(beyond.z) + "); " + radar + " radar, " + t1 + " T1", 1);
        if (provider == ai.teamId) Request(top, beyond, radar, t1, ai.teamId);
        else AiSendMessage(PREFIX + top.x + "|" + top.z + "|" + beyond.x + "|" + beyond.z + "|" + radar + "|" + t1, provider);
    }

    // LolCannon::Tick (every second): each standing cannon's best area
    void CannonTick()
    {
        if (!Global::LolCannon::StrikeScout || ai.frame < nextCheck) return;
        nextCheck = ai.frame + 2 * SECOND;
        for (int i = int(cannonIds.length()) - 1; i >= 0; --i) {
            CCircuitUnit@ u = ai.GetTeamUnit(cannonIds[i]);
            if (u is null) { cannonIds.removeAt(i); askedPos.removeAt(i); askedAt.removeAt(i); continue; }
            CSuperTask@ st = cast<CSuperTask>(u.task);
            if (st is null || st.GetTierAreaCount() <= 0) continue;
            const AIFloat3 top = st.GetTierAreaPos(0);
            const float r = Global::LolCannon::FireAreaRadius;
            string why = "";
            if (askedPos[i].x < 0.0f) why = "the first area targeted";
            else if (MapHelpers::SqDist(top, askedPos[i]) > r * r) why = "the highest-rated area changed";
            else if (ai.frame - askedAt[i] >= Global::LolCannon::StrikeScoutSeconds * SECOND) why = "is it destroyed?";
            if (why == "") continue;
            askedPos[i] = top; askedAt[i] = ai.frame;
            Ask(u, top, st.GetTierAreaTargetId(0), why);
        }
    }

    // ------------------------------------------------------------ the scouting side
    bool active = false;
    AIFloat3 target, beyond;
    int wantRadar = 0, wantT1 = 0, version = 0, askedBy = -1;
    dictionary members;     // unit id -> slot
    dictionary routes;      // unit id -> CRouteTask@
    array<IUnitTask@> recruits;
    int checked = -SECOND;

    bool Handle(const string &in msg, int fromTeamId)
    {
        if (msg.findFirst(PREFIX) != 0) return false;
        array<string>@ p = msg.split("|");
        if (p.length() < 8) return true;
        Request(AIFloat3(parseFloat(p[2]), 0.0f, parseFloat(p[3])), AIFloat3(parseFloat(p[4]), 0.0f, parseFloat(p[5])),
            parseInt(p[6]), parseInt(p[7]), fromTeamId);
        return true;
    }

    int Kind(const CCircuitDef@ d)
    {
        if (d is null) return -1;
        const string name = d.GetName();
        const string side = UnitHelpers::GetSideForUnitName(name);
        return name == UnitHelpers::GetT1AirScoutForSide(side) ? 0 : name == AirRecon::Name(side) ? 1 : -1;
    }
    int Wanted(int kind) { return kind == 0 ? wantT1 : wantRadar; }
    int Count(int kind)
    {
        int n = 0;
        array<string>@ ids = members.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            if (u !is null && Kind(u.circuitDef) == kind) ++n;
        }
        return n;
    }

    // slot k's two waypoints: a point round the area (radar planes on the inner
    // ring, T1 scouts on the outer), then the edge beyond, spread across
    void Waypoints(int slot, AIFloat3 &out p, AIFloat3 &out b)
    {
        const int total = AiMax(1, wantRadar + wantT1);
        const float spread = Global::LolCannon::StrikeSpread;
        const float ring = (slot < wantRadar) ? spread * 0.35f : spread * (0.6f + 0.4f * float(slot % 2));
        const float angle = 6.2831853f * float(slot) / float(total);
        p = Clamp(AIFloat3(target.x + cos(angle) * ring, 0.0f, target.z + sin(angle) * ring));
        float dx = beyond.x - target.x, dz = beyond.z - target.z;
        const float len = AiMax(1.0f, sqrt(dx * dx + dz * dz));
        dx /= len; dz /= len;
        const float across = (total > 1) ? (float(slot) / float(total - 1) - 0.5f) * 2.0f * spread : 0.0f;
        b = Clamp(AIFloat3(beyond.x - dz * across, 0.0f, beyond.z + dx * across));
    }

    CRouteTask@ Route(int slot)
    {
        CRouteTask@ task = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (task is null) return null;
        AIFloat3 p, b;
        Waypoints(slot, p, b);
        task.SetAirControl(true);
        task.SetTraversal(true, 256, false);
        task.SetRoute(array<AIFloat3> = { p, b });
        return task;
    }

    int FreeSlot(int kind)
    {
        array<bool> used(wantRadar + wantT1, false);
        array<string>@ ids = members.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            int s = -1;
            members.get(ids[i], s);
            if (s >= 0 && s < int(used.length())) used[s] = true;
        }
        const int from = (kind == 1) ? 0 : wantRadar, to = (kind == 1) ? wantRadar : wantRadar + wantT1;
        for (int s = from; s < to; ++s) if (!used[s]) return s;
        return -1;
    }

    void Request(const AIFloat3 &in at, const AIFloat3 &in edge, int radar, int t1, int fromTeamId)
    {
        target = at; beyond = edge; wantRadar = AiMax(0, radar); wantT1 = AiMax(0, t1);
        active = true; ++version; askedBy = fromTeamId;
        // the living squad flies again at once
        int sent = 0;
        array<string>@ ids = members.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            int slot = -1;
            members.get(ids[i], slot);
            if (u is null || u.GetBuildProgress() < 1.0f || !AirRecon::Controlled(u)) continue;
            CRouteTask@ old;
            if (routes.get(ids[i], @old) && old !is null && !old.IsDead()) old.Abort();
            CRouteTask@ task = Route(slot);
            if (task is null) continue;
            if (!aiMilitaryMgr.TransferUnit(u, task)) { task.Abort(); continue; }
            routes.set(ids[i], @task);
            ++sent;
        }
        GenericHelpers::LogUtil("[LolCannon][StrikeScout] request from team " + fromTeamId + ": scout (" + int(at.x) + ", " + int(at.z)
            + ") then the edge at (" + int(edge.x) + ", " + int(edge.z) + "); squad " + Count(1) + "/" + wantRadar + " radar, "
            + Count(0) + "/" + wantT1 + " T1; " + sent + " sent again", 1);
    }

    // Military AiMakeTask: a squad member, or a new scout the squad is short of
    IUnitTask@ TaskFor(CCircuitUnit@ u)
    {
        if (!active || u is null || u.circuitDef is null || u.GetBuildProgress() < 1.0f || !AirRecon::Controlled(u)) return null;
        const int kind = Kind(u.circuitDef);
        if (kind < 0) return null;
        const string key = "" + u.id;
        CRouteTask@ task;
        if (members.exists(key)) {
            if (routes.get(key, @task) && task !is null && !task.IsDead()) return task;
            return null;   // its flight ended: free until the next request
        }
        if (Count(kind) >= Wanted(kind)) return null;
        const int slot = FreeSlot(kind);
        if (slot < 0) return null;
        @task = Route(slot);
        if (task is null) return null;
        members.set(key, slot);
        routes.set(key, @task);
        u.SetIdleMode(0);
        u.SetFireState(0);
        AIFloat3 p, b;
        Waypoints(slot, p, b);
        GenericHelpers::LogUtil("[LolCannon][StrikeScout] " + u.circuitDef.GetName() + " " + u.id + " slot " + slot + " flies to ("
            + int(p.x) + ", " + int(p.z) + ") then (" + int(b.x) + ", " + int(b.z) + ")", 1);
        return task;
    }

    int Pending()
    {
        for (int i = int(recruits.length()) - 1; i >= 0; --i) if (recruits[i] is null || recruits[i].IsDead()) recruits.removeAt(i);
        return int(recruits.length());
    }

    // Factory AiMakeTask: an air plant builds what the squad is missing
    IUnitTask@ Produce(CCircuitUnit@ plant)
    {
        if (!active || plant is null || plant.circuitDef is null || plant.GetBuildProgress() < 1.0f) return null;
        const string fname = plant.circuitDef.GetName();
        const bool t1 = UnitHelpers::IsT1AircraftPlant(fname), t2 = UnitHelpers::IsT2AircraftPlant(fname);
        if (!t1 && !t2) return null;
        const string side = UnitHelpers::GetSideForUnitName(fname);
        const int kind = t2 ? 1 : 0;
        CCircuitDef@ d = ai.GetCircuitDef(kind == 0 ? UnitHelpers::GetT1AirScoutForSide(side) : AirRecon::Name(side));
        if (d is null || !plant.circuitDef.CanBuild(d)) return null;
        // the projected squad: members, finished scouts of the kind not yet claimed are left to their owners
        const int missing = Wanted(kind) - Count(kind) - aiFactoryMgr.GetPendingRecruitCount(d);
        if (missing <= 0 || Pending() >= wantRadar + wantT1) return null;
        if (d.maxThisUnit <= d.count + missing) d.maxThisUnit = d.count + missing + 1;   // role caps yield to the squad
        IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, plant.GetPos(ai.frame), 64.0f));
        if (r !is null) recruits.insertLast(r);
        return r;
    }

    // economy tick (every second): forget the dead
    void Tick()
    {
        if (!active || ai.frame - checked < SECOND) return;
        checked = ai.frame;
        array<string>@ ids = members.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            if (ai.GetTeamUnit(parseInt(ids[i])) !is null) continue;
            members.delete(ids[i]); routes.delete(ids[i]);
        }
    }
}
