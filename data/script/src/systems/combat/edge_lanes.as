// Edge lanes (owner, 2026-10-17): two FRONTs each build one spam lab that sends
// its units down one edge of the map.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../team/roster.as"

/******************************************************************************

EDGE LANES

Two special spam lanes, one along each side edge of the map. The axis runs
from the centre of our team's starts to the centre of the enemy team's starts;
"left" and "right" are the two sides of it.

  rally 1   on the map edge on that side, EdgeFirstShare (1/3) of the way
            along the axis toward the enemy
  rally 2   on the same edge, EdgeSecondShare (2/3) of the way
  rally 3   the far corner on that side (the map corner furthest along the
            axis and toward that edge)

Each point is pulled inward from the edge (map corner toward the centre) until
it stands in the spam unit's own movement area reachable from its lab: the
same test Spam uses for its routes (CanTraverse), so a rally point is never on
a cliff, in deep water or outside the playable ground.

The lanes are given to two FRONTs: of the team's FRONT SMRTBARbs (this one
and the roster), the one furthest to the left of the axis takes the left lane
and the one furthest to the right takes the right lane. A lone FRONT takes
the lane on its own side. Every FRONT computes the same order from the same
starts, so no message is needed.

Each lane's FRONT builds one spam cluster the way TECH builds its spam labs
(D-114/D-119): two construction turrets directly behind the planned lab, the
turrets first, then the lab (a T1 bot lab, or a T1 vehicle plant when
EdgeVehicleLab). Native placement: FRONT has no layout reservations, so the
lab faces the way native would face it (toward the map centre) and the
turrets are ordered behind that.

The lane starts (cluster, then production) once FRONT has a finished T2
factory and has held EdgeMinMetalIncome (65) and EdgeMinEnergyIncome for 10 s;
below ReleaseFraction of them it pauses. The lab produces
Spam::SpamUnitFor(lab) on repeat (native repeat recruit, as
Spam::FactoryMakeTask) while the lane is on. Its units take the lane as their factory route
(CmdFactoryRoute: the first rally, then the next two shift-queued) and join
the lab's Spam route task (Spam::RouteFor / MilitaryMakeTask), which holds
them on the lane and at the far corner. The edge lab is not one of Spam's
income-scaled pumps: it never counts toward LabsWanted, never takes a spread
lane, and is never lent to heavy delivery.

******************************************************************************/
namespace EdgeLanes {
    int lane = 0;               // -1 left, +1 right, 0 none
    bool decided = false;
    bool funded = false;
    AIFloat3 site(-1.0f, 0.0f, -1.0f);   // the planned lab's centre
    int facing = 0;
    array<AIFloat3> turretSite;
    array<IUnitTask@> turretTask(2);
    array<int> turretFrame = {-1, -1};
    array<int> turretOrder = {-1, -1};   // the last order's frame
    array<int> turretFails = {0, 0};     // orders that died with no turret
    IUnitTask@ labTask;
    int labOrderFrame = -1;
    int labId = -1;
    IUnitTask@ repeat;
    int planFrame = -100000;
    int routeSent = -1;         // Spam::routesVersion last given to the lab as its factory route
    array<AIFloat3> rally;      // the lane's three rally points, from the lab

    bool Enabled()
    {
        return Global::Spam::EdgeLanesEnabled && Global::AISettings::Role == AiRole::FRONT && Spam::IsEnabled();
    }

    // ---------------------------------------------------------------- geometry

    AIFloat3 Centre(const array<AIFloat3> &in ps)
    {
        float x = 0.0f, z = 0.0f;
        for (uint i = 0; i < ps.length(); ++i) { x += ps[i].x; z += ps[i].z; }
        const float n = float(AiMax(1, int(ps.length())));
        return AIFloat3(x / n, 0.0f, z / n);
    }

    // Our team's centre S, the enemy's centre E; false without an enemy.
    bool Ends(AIFloat3 &out s, AIFloat3 &out e)
    {
        array<AIFloat3> ours = Lanes::ScriptStarts(false);
        if (ours.length() == 0) {
            ours.insertLast(Global::Map::StartPos);
            array<Team::Roster::Entry@>@ allies = Team::Roster::All();
            for (uint i = 0; i < allies.length(); ++i) ours.insertLast(allies[i].startPos);
        }
        array<AIFloat3> theirs = Lanes::EnemyStarts();
        s = Centre(ours);
        e = (theirs.length() > 0) ? Centre(theirs) : Spam::_MirrorOfStart();
        return MapHelpers::SqDist(s, e) > 1.0f;
    }
    void Axis(const AIFloat3 &in s, const AIFloat3 &in e, float &out ax, float &out az, float &out nx, float &out nz)
    {
        ax = e.x - s.x; az = e.z - s.z;
        const float len = sqrt(ax * ax + az * az);
        ax /= len; az /= len;
        nx = -az; nz = ax;
    }

    bool InBounds(const AIFloat3 &in p)
    {
        const float m = Global::Spam::EdgeMargin;
        return p.x >= m && p.z >= m && p.x <= float(AiTerrainWidth()) - m && p.z <= float(AiTerrainHeight()) - m;
    }
    // Playable for the spam unit: inside the margin and in its movement area,
    // reachable from the lab (as Spam's routes test every waypoint)
    bool Playable(CCircuitDef@ d, const AIFloat3 &in from, const AIFloat3 &in p)
    {
        return InBounds(p) && aiTerrainMgr.CanTraverse(d, from, p);
    }
    // From `p` toward `to`, 128 elmos a step: the first playable point
    AIFloat3 PullIn(CCircuitDef@ d, const AIFloat3 &in from, const AIFloat3 &in p, const AIFloat3 &in to)
    {
        const float dx = to.x - p.x, dz = to.z - p.z;
        const float len = sqrt(dx * dx + dz * dz);
        const int steps = int(len / 128.0f);
        for (int k = 0; k <= steps; ++k) {
            const float f = (len < 1.0f) ? 0.0f : float(k) * 128.0f / len;
            const AIFloat3 q(p.x + dx * f, 0.0f, p.z + dz * f);
            if (Playable(d, from, q)) return q;
        }
        return AIFloat3(-1.0f, 0.0f, -1.0f);
    }
    // The edge on side `s` at `share` of the way from S to E: straight out
    // sideways from the axis point to the margin, then pulled back inward
    AIFloat3 EdgePoint(CCircuitDef@ d, const AIFloat3 &in from, const AIFloat3 &in s0, const AIFloat3 &in e0, int s, float share)
    {
        float ax, az, nx, nz;
        Axis(s0, e0, ax, az, nx, nz);
        const AIFloat3 p(s0.x + (e0.x - s0.x) * share, 0.0f, s0.z + (e0.z - s0.z) * share);
        const float dx = nx * float(s), dz = nz * float(s);
        const float m = Global::Spam::EdgeMargin;
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        float t = 1.0e30f;
        if (dx > 0.001f) t = AiMin(t, (w - m - p.x) / dx);
        if (dx < -0.001f) t = AiMin(t, (m - p.x) / dx);
        if (dz > 0.001f) t = AiMin(t, (h - m - p.z) / dz);
        if (dz < -0.001f) t = AiMin(t, (m - p.z) / dz);
        if (t > 1.0e29f || t < 0.0f) t = 0.0f;
        const AIFloat3 edge(p.x + dx * t, 0.0f, p.z + dz * t);
        return PullIn(d, from, edge, p);
    }
    // The far corner on side `s`: the margin corner furthest along (axis + side)
    AIFloat3 CornerPoint(CCircuitDef@ d, const AIFloat3 &in from, const AIFloat3 &in s0, const AIFloat3 &in e0, int s)
    {
        float ax, az, nx, nz;
        Axis(s0, e0, ax, az, nx, nz);
        const float m = Global::Spam::EdgeMargin;
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        const array<float> cx = { m, w - m, m, w - m }, cz = { m, m, h - m, h - m };
        int best = 0;
        float bestScore = -1.0e30f;
        for (int i = 0; i < 4; ++i) {
            const float score = (cx[i] - s0.x) * (ax + nx * float(s)) + (cz[i] - s0.z) * (az + nz * float(s));
            if (score > bestScore) { bestScore = score; best = i; }
        }
        return PullIn(d, from, AIFloat3(cx[best], 0.0f, cz[best]), AIFloat3(w * 0.5f, 0.0f, h * 0.5f));
    }
    // The lane's three rally points from `from`; empty when one has no playable point
    array<AIFloat3> Rally(CCircuitDef@ d, const AIFloat3 &in from)
    {
        array<AIFloat3> r;
        AIFloat3 s0, e0;
        if (lane == 0 || d is null || !Ends(s0, e0)) return r;
        const AIFloat3 r1 = EdgePoint(d, from, s0, e0, lane, Global::Spam::EdgeFirstShare);
        const AIFloat3 r2 = EdgePoint(d, from, s0, e0, lane, Global::Spam::EdgeSecondShare);
        const AIFloat3 r3 = CornerPoint(d, from, s0, e0, lane);
        if (r1.x < 0.0f || r2.x < 0.0f || r3.x < 0.0f) return r;
        r.insertLast(r1); r.insertLast(r2); r.insertLast(r3);
        return r;
    }
    string Name(int s) { return (s < 0) ? "left" : "right"; }

    // ---------------------------------------------------------------- which FRONTs

    // The FRONTs ordered by their sideways place: the leftmost takes -1, the
    // rightmost +1; decided once the roster is complete (or after 3 minutes)
    int Decide()
    {
        if (decided) return lane;
        if (!Team::Roster::IsComplete() && ai.frame < 3 * MINUTE) return 0;
        AIFloat3 s0, e0;
        if (!Ends(s0, e0)) return 0;
        float ax, az, nx, nz;
        Axis(s0, e0, ax, az, nx, nz);
        array<int> teams = { ai.teamId };
        array<float> sides = { (Global::Map::StartPos.x - s0.x) * nx + (Global::Map::StartPos.z - s0.z) * nz };
        array<Team::Roster::Entry@>@ fronts = Team::Roster::WithRole(AiRole::FRONT);
        for (uint i = 0; i < fronts.length(); ++i) {
            if (fronts[i].teamId == ai.teamId) continue;
            teams.insertLast(fronts[i].teamId);
            sides.insertLast((fronts[i].startPos.x - s0.x) * nx + (fronts[i].startPos.z - s0.z) * nz);
        }
        int left = 0, right = 0;
        for (uint i = 1; i < teams.length(); ++i) {
            if (sides[i] < sides[left] || (sides[i] == sides[left] && teams[i] < teams[left])) left = int(i);
            if (sides[i] > sides[right] || (sides[i] == sides[right] && teams[i] < teams[right])) right = int(i);
        }
        if (teams.length() == 1) lane = (sides[0] < 0.0f) ? -1 : 1;
        else if (left == 0) lane = -1;
        else if (right == 0) lane = 1;
        else lane = 0;
        decided = true;
        GenericHelpers::LogUtil("[EdgeLanes] " + teams.length() + " FRONT(s); this one (team " + ai.teamId + ", "
            + int(sides[0]) + " elmos sideways) " + ((lane == 0) ? "takes no edge lane" : ("takes the " + Name(lane) + " edge lane")), 1);
        return lane;
    }

    // ---------------------------------------------------------------- economy

    // Main::AiUpdate (via Spam::Update), every 30 frames
    void Update()
    {
        if (!Enabled()) { funded = false; return; }
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        const float keep = funded ? Global::Spam::ReleaseFraction : 1.0f;
        // owner, 2026-10-17: start only with a finished T2 factory and the
        // income held for 10 s (the sliding minimum); once on, ReleaseFraction pauses
        const bool t2 = funded || !Global::Spam::EdgeNeedsT2Factory || HasT2Factory();
        const bool now = t2 && mi >= Global::Spam::EdgeMinMetalIncome * keep && ei >= Global::Spam::EdgeMinEnergyIncome * keep
            && aiBuilderMgr.GetWorkerCount() >= Global::Spam::MinWorkers;
        if (now != funded) {
            funded = now;
            GenericHelpers::LogUtil("[EdgeLanes] " + (now ? "funded" : "paused") + ": mi=" + int(mi) + "/" + int(Global::Spam::EdgeMinMetalIncome)
                + " ei=" + int(ei) + "/" + int(Global::Spam::EdgeMinEnergyIncome) + " T2 factory=" + (HasT2Factory() ? "yes" : "no"), 1);
        }
        CCircuitUnit@ lab = Lab();
        if (repeat !is null && (repeat.IsDead() || lab is null || lab.task !is repeat)) @repeat = null;
        if (repeat !is null && !funded) {
            repeat.Abort();   // the lab asks again; its units on the lane keep going
            @repeat = null;
        }
        if (lab !is null && repeat !is null && routeSent != Spam::routesVersion) {
            lab.CmdFactoryRoute(Spam::RouteOf(lab));
            routeSent = Spam::routesVersion;
        }
        if (repeat !is null) {
            CCircuitDef@ d = ai.GetCircuitDef(Spam::SpamUnitFor(lab.circuitDef));
            if (d !is null && d.maxThisUnit < d.count + 50) d.maxThisUnit = d.count + 50;
        }
        Report(lab);
    }
    // Once a minute: how many units run the lane and how far the leader got
    int reportFrame = -1;
    void Report(CCircuitUnit@ lab)
    {
        if (lab is null || rally.length() < 3 || ai.frame - reportFrame < MINUTE) return;
        reportFrame = ai.frame;
        CRouteTask@ task = null;
        if (!Spam::routeByFactory.get("" + lab.id, @task) || task is null || task.IsDead()) return;
        array<CCircuitUnit@>@ us = task.GetUnits();
        float best = 1.0e30f;
        AIFloat3 lead(-1.0f, 0.0f, -1.0f);
        for (uint i = 0; i < us.length(); ++i) {
            const AIFloat3 q = us[i].GetPos(ai.frame);
            const float sq = MapHelpers::SqDist(q, rally[2]);
            if (sq < best) { best = sq; lead = q; }
        }
        GenericHelpers::LogUtil("[EdgeLanes] " + Name(lane) + " lane: " + us.length() + " unit(s) on it; nearest the corner at ("
            + int(lead.x) + "," + int(lead.z) + "), " + int(sqrt(best)) + " from it", 1);
    }

    // A finished T2 bot lab or vehicle plant of ours
    bool HasT2Factory()
    {
        array<string> names = UnitHelpers::GetAllT2BotLabs();
        array<string> vp = UnitHelpers::GetAllT2VehicleLabs();
        for (uint i = 0; i < vp.length(); ++i) names.insertLast(vp[i]);
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d !is null && d.count > aiBuilderMgr.GetUnfinishedCount(d)) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- the cluster

    CCircuitDef@ LabDef()
    {
        const string side = Global::AISettings::Side;
        if (!Global::Spam::EdgeVehicleLab) return ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side));
        if (side == "cortex") return ai.GetCircuitDef("corvp");
        if (side == "legion") return ai.GetCircuitDef("legvp");
        return ai.GetCircuitDef("armvp");
    }
    CCircuitDef@ Nano() { return ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)); }
    CCircuitUnit@ Lab()
    {
        if (labId >= 0) {
            CCircuitUnit@ u = ai.GetTeamUnit(labId);
            if (u !is null) return u;
            labId = -1;
        }
        CCircuitDef@ d = LabDef();
        if (d is null || site.x < 0.0f) return null;
        CCircuitUnit@ f = aiBuilderMgr.FindOwnNear(site, 96.0f, d);
        if (f is null) @f = aiBuilderMgr.FindUnfinishedNear(site, 96.0f, d);
        if (f !is null) labId = f.id;
        return f;
    }
    bool IsEdgeLab(CCircuitUnit@ f) { return f !is null && labId >= 0 && f.id == labId; }
    bool IsEdgeKey(const string &in key) { return labId >= 0 && key == ("" + labId); }

    // Native's own factory facing (IBuilderTask::FindFacing): toward the map
    // centre along the longer offset
    int NativeFacing(const AIFloat3 &in p)
    {
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        if (abs(w - 2.0f * p.x) > abs(h - 2.0f * p.z)) return (2.0f * p.x > w) ? 3 : 1;
        return (2.0f * p.z > h) ? 2 : 0;
    }
    // The two turret sites directly behind the lab at `p` facing `f`, side by side
    array<AIFloat3> TurretSites(CCircuitDef@ lab, CCircuitDef@ nano, const AIFloat3 &in p, int f)
    {
        const float cell = SQUARE_SIZE * 2;
        const float back = (float(Layout::Along(lab, f)) * 0.5f + float(Layout::Along(nano, f)) * 0.5f) * cell;
        const float across = float(Layout::Across(nano, f)) * 0.5f * cell;
        const AIFloat3 b = p - Layout::Fwd(f) * back;
        array<AIFloat3> r = { b - Layout::Side(f) * across, b + Layout::Side(f) * across };
        return r;
    }

    // A site on our side of the lane's edge: out from our start toward that
    // edge, the first where the lab, its turrets and its exit fit on flat,
    // free ground and the spam unit can walk from it to the lane's first rally
    bool PlanSite(CCircuitUnit@ u, CCircuitDef@ lab, CCircuitDef@ nano, CCircuitDef@ product)
    {
        if (ai.frame - planFrame < 30 * SECOND) return false;
        planFrame = ai.frame;
        AIFloat3 s0, e0;
        if (!Ends(s0, e0)) return false;
        float ax, az, nx, nz;
        Axis(s0, e0, ax, az, nx, nz);
        const AIFloat3 home = Global::Map::StartPos;
        // toward the lane's edge first; a FRONT already near that edge looks back inward
        const array<float> outward = { 400.0f, 700.0f, 1000.0f, 1300.0f, 0.0f, -400.0f, -700.0f, -1000.0f, -1300.0f, -1600.0f };
        const array<float> along = { 0.0f, 300.0f, -300.0f, 600.0f, -600.0f, 900.0f, -900.0f };
        const float cell = SQUARE_SIZE * 2;
        // why candidates fail, for the log: map, passable/reach, ally layout, flat, room, exit, rally
        array<int> why = { 0, 0, 0, 0, 0, 0, 0 };
        // first pass roomy and flat as TECH's front clusters (D-114), then looser
        for (int pass = 0; pass < 2; ++pass) {
            const float flat = (pass == 0) ? Global::RoleSettings::Tech::FrontMinFlat : 0.6f;
            const float room = (pass == 0) ? Global::RoleSettings::Tech::FrontRoomyShare : 0.6f;
            const float pad = (pass == 0) ? cell : 0.0f;
            for (uint i = 0; i < outward.length(); ++i) for (uint j = 0; j < along.length(); ++j) {
                const AIFloat3 p(home.x + nx * float(lane) * outward[i] + ax * along[j], 0.0f, home.z + nz * float(lane) * outward[i] + az * along[j]);
                if (p.x < 256.0f || p.z < 256.0f || p.x > float(AiTerrainWidth()) - 256.0f || p.z > float(AiTerrainHeight()) - 256.0f) { ++why[0]; continue; }
                const int f = NativeFacing(p);
                const float halfAcross = float(Layout::Across(lab, f)) * 0.5f * cell;
                const float halfAlong = float(Layout::Along(lab, f) + Layout::Along(nano, f)) * 0.5f * cell;
                const AIFloat3 centre = p - Layout::Fwd(f) * (float(Layout::Along(nano, f)) * 0.5f * cell);
                if (!aiBattle.IsPassable(p, Lanes::BOT) || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())) { ++why[1]; continue; }
                if (aiTerrainMgr.IsAllyLayoutBlocked(lab, p, f)) { ++why[2]; continue; }
                if (aiTerrainMgr.FlatFraction(centre, f, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope) < flat) { ++why[3]; continue; }
                if (aiTerrainMgr.BuildableFraction(lab, centre, halfAcross + pad, halfAlong + pad, f) < room) { ++why[4]; continue; }
                if (!aiTerrainMgr.IsExitClear(lab, p, f, 320.0f, 32.0f)) { ++why[5]; continue; }
                array<AIFloat3> r = Rally(product, p);
                if (r.length() == 0) { ++why[6]; continue; }
                site = p;
                facing = f;
                turretSite = TurretSites(lab, nano, p, f);
                rally = r;
                GenericHelpers::LogUtil("[EdgeLanes] " + Name(lane) + " lane lab site (" + int(p.x) + "," + int(p.z) + ") facing " + f
                    + " (pass " + (pass + 1) + "); rally (" + int(r[0].x) + "," + int(r[0].z) + ") -> (" + int(r[1].x) + "," + int(r[1].z) + ") -> corner ("
                    + int(r[2].x) + "," + int(r[2].z) + ")", 1);
                return true;
            }
        }
        GenericHelpers::LogUtil("[EdgeLanes] candidates refused: map " + why[0] + ", passable/reach " + why[1] + ", ally layout " + why[2]
            + ", flat " + why[3] + ", room " + why[4] + ", exit " + why[5] + ", rally " + why[6], 1);
        GenericHelpers::LogUtil("[EdgeLanes] no site for the " + Name(lane) + " lane lab yet (retry in 30 s)", 1);
        return false;
    }

    // Join a live order (at most two builders), else null
    IUnitTask@ Join(IUnitTask@ t)
    {
        if (t is null || t.IsDead()) return null;
        return (t.GetUnits().length() < 2) ? t : null;
    }

    // Builder::AiMakeTask asks here before Spam
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || !funded || u is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        if (Decide() == 0) return null;
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        CCircuitDef@ lab = LabDef();
        CCircuitDef@ nano = Nano();
        if (lab is null || nano is null || !u.circuitDef.CanBuild(lab) || !u.circuitDef.CanBuild(nano)) return null;
        CCircuitDef@ product = ai.GetCircuitDef(Spam::SpamUnitFor(lab));
        if (product is null) return null;
        if (site.x < 0.0f && !PlanSite(u, lab, nano, product)) return null;
        // 1. the two turrets, directly behind the lab, before it
        int standing = 0;
        bool pending = false;
        for (uint i = 0; i < 2; ++i) {
            CCircuitUnit@ t = aiBuilderMgr.FindOwnNear(turretSite[i], 56.0f, nano);
            if (t !is null && t.GetBuildProgress() >= 1.0f) { ++standing; turretFrame[i] = -1; turretFails[i] = 0; turretOrder[i] = -1; continue; }
            if (t is null) @t = aiBuilderMgr.FindUnfinishedNear(turretSite[i], 56.0f, nano);
            if (t !is null) { turretOrder[i] = -1; return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, t, 30 * SECOND)); }
            IUnitTask@ joined = Join(turretTask[i]);
            if (joined !is null) return joined;
            if (turretTask[i] !is null && !turretTask[i].IsDead()) { pending = true; continue; }
            // an order that died with no turret: native refused the spot. After two,
            // let native look round it; after six (or 240 s) the lab goes up behind
            // what stands, as TECH's clusters do with a dead slot
            if (turretOrder[i] >= 0) { ++turretFails[i]; turretOrder[i] = -1; }
            if (turretFails[i] >= 6 || (turretFrame[i] >= 0 && ai.frame - turretFrame[i] >= 240 * SECOND)) continue;
            if (nano.maxThisUnit <= nano.count) nano.maxThisUnit = nano.count + 1;
            if (!nano.IsAvailable(ai.frame)) return null;
            @turretTask[i] = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO, Task::Priority::HIGH, nano, turretSite[i],
                (turretFails[i] >= 2) ? 96.0f : 0.0f, true, 120 * SECOND));
            if (turretTask[i] is null) { ++turretFails[i]; return null; }
            turretOrder[i] = ai.frame;
            if (turretFrame[i] < 0) turretFrame[i] = ai.frame;
            GenericHelpers::LogUtil("[EdgeLanes] " + u.circuitDef.GetName() + " " + u.id + " orders turret " + (i + 1) + " of the "
                + Name(lane) + " lane lab at (" + int(turretSite[i].x) + "," + int(turretSite[i].z) + ")", 1);
            return turretTask[i];
        }
        // 2. the lab, once both turrets stand (or the turret orders gave up)
        CCircuitUnit@ f = Lab();
        if (f !is null) {
            if (f.GetBuildProgress() < 1.0f) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, f, 30 * SECOND));
            return null;   // it stands; its turrets assist it
        }
        if (standing == 0 || pending) return null;   // a turret order still lives: the cluster waits
        IUnitTask@ joined = Join(labTask);
        if (joined !is null) return joined;
        if (labTask !is null && !labTask.IsDead()) {
            if (ai.frame - labOrderFrame < 300 * SECOND) return null;
            aiBuilderMgr.AbortTask(labTask);   // the order never became a frame: plan again
            @labTask = null;
            site = AIFloat3(-1.0f, 0.0f, -1.0f);
            turretFrame[0] = -1; turretFrame[1] = -1;
            turretOrder[0] = -1; turretOrder[1] = -1;
            turretFails[0] = 0; turretFails[1] = 0;
            GenericHelpers::LogUtil("[EdgeLanes] the " + Name(lane) + " lane lab order made no frame in 300 s; planning another site", 1);
            return null;
        }
        if (lab.maxThisUnit <= lab.count) lab.maxThisUnit = lab.count + 1;
        if (!lab.IsAvailable(ai.frame)) return null;
        @labTask = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::HIGH, lab, site, product, 0.0f, false, true, 300 * SECOND));
        labOrderFrame = ai.frame;
        GenericHelpers::LogUtil("[EdgeLanes] " + u.circuitDef.GetName() + " " + u.id + " orders the " + Name(lane) + " lane "
            + lab.GetName() + " at (" + int(site.x) + "," + int(site.z) + ") (" + standing + " of 2 turrets stand)", 1);
        return labTask;
    }

    // ---------------------------------------------------------------- production

    // Spam::FactoryMakeTask asks here first: the edge lab spams on repeat while funded
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!Enabled() || !funded || factory is null || lane == 0) return null;
        if (labId < 0) Lab();
        if (!IsEdgeLab(factory) || factory.GetBuildProgress() < 1.0f) return null;
        if (repeat !is null && !repeat.IsDead()) return null;
        const string unitName = Spam::SpamUnitFor(factory.circuitDef);
        CCircuitDef@ d = ai.GetCircuitDef(unitName);
        if (d is null) return null;
        if (d.maxThisUnit < d.count + 50) d.maxThisUnit = d.count + 50;
        if (!d.IsAvailable(ai.frame)) return null;
        if (Spam::RouteFor(factory) is null) return null;
        factory.CmdFactoryRoute(Spam::RouteOf(factory));
        routeSent = Spam::routesVersion;
        @repeat = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, d,
            factory.GetPos(ai.frame), 64.f, true));
        GenericHelpers::LogUtil("[EdgeLanes] repeat factory=" + factory.id + " unit=" + unitName + " on the " + Name(lane) + " edge lane", 1);
        return repeat;
    }

    // Spam::_RouteOfKey: the edge lab's route (cached; recomputed if it went empty)
    array<AIFloat3> Route(CCircuitDef@ d, const AIFloat3 &in from)
    {
        if (rally.length() == 0) rally = Rally(d, from);
        return rally;
    }

    void OnFactoryRemoved(CCircuitUnit@ factory)
    {
        if (!IsEdgeLab(factory)) return;
        labId = -1;
        @repeat = null;
        @labTask = null;
        routeSent = -1;
        GenericHelpers::LogUtil("[EdgeLanes] the " + Name(lane) + " lane lab was lost; its builders rebuild it", 1);
    }
}  // namespace EdgeLanes
